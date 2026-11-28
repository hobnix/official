// The service of the media hub (hobnix/core#928, ported to Rust in hobnix/extensions#27; docs/extensions-sdk.md "Write it in Rust", ADR 0011).
// One process that stays:
//   - the poller: every HS_MEDIA_POLL_SECONDS (default 30; 0 = off) it asks the media apps who plays what (adapter.rs, one adapter per app), counts a
//     finished playback (a `rollup` and an `emit` of session-completed, both through the service protocol) and publishes who plays now as the snapshot
//     topic now-playing (one document, overwritten).
// The poster of an `imported` event is not drawn here: the package `posters` handles pkg.media-hub.imported itself (its service poster-svc.py), so this
// service never runs a host command for it.
// The protocol has no timer, so the service is the timer (a worker thread). It starts no change on storage: that is a suggestion the person confirms.
// The media apps (provider, address, header) come from `init.integrations` (`ctx.integrations()`), the core builds them: this service runs no `hs`.
// Keys: only through `ctx.credential("media", <provider>)` ($CREDENTIALS_DIRECTORY/integration-media-<provider>), never argv or environment, never
// logged, and a key goes only to the address of the provider it belongs to. Plain http only: an https address is named in the log, not polled.
// State folder: $STATE_DIRECTORY (systemd). Test knobs: HS_MEDIA_STATE_DIR,
// HS_MEDIA_POLL_SECONDS, HS_MEDIA_MIN_SECONDS (the shortest playback that counts, default 60).
mod adapter;
mod poll;

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::{mpsc, Arc, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use hobnix_pkg::http::{Client, HttpError};
use hobnix_pkg::{Ctx, Error, Event, LogLevel};
use hobnix_pkg_service::{run, Health, Init, Service};
use serde_json::{json, Map, Value};

use poll::{clean, parse_apps, user_name, App, Finished, Playing, Poller};

const SESSION_KIND: &str = "pkg.media-hub.session-completed"; // declared in package.toml with retention = "metric": the rollup kind
const HTTP_TIMEOUT: Duration = Duration::from_secs(5);

fn env_f64(name: &str, default: f64) -> f64 {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok()).filter(|v: &f64| v.is_finite() && *v >= 0.0).unwrap_or(default)
}

fn now_secs() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0.0, |d| d.as_secs_f64())
}

fn log(ctx: &dyn Ctx, level: LogLevel, text: &str) {
    let _ = ctx.log(level, text);
}

/// What the poller says about itself between rounds: it must not repeat a line every 30 seconds.
#[derive(Default)]
struct Said {
    failed: HashMap<String, String>, // package -> the last failure that was logged
    keyless: HashSet<String>,
}

/// GET the sessions of one app with ITS key in its header. The key is read per call and never logged.
fn fetch(ctx: &dyn Ctx, said: &mut Said, app: &App) -> Option<String> {
    let ad = adapter::adapter(&app.package)?;
    let Some(key) = ctx.credential("media", &app.package).filter(|k| !k.is_empty()) else {
        if said.keyless.insert(app.package.clone()) {
            log(ctx, LogLevel::Warn, &format!("poller: no key handed over for {} (integration-media-{}): not polled", app.package, app.package));
        }
        return None;
    };
    said.keyless.remove(&app.package);
    let url = format!("{}{}", app.url.trim_end_matches('/'), ad.endpoint);
    let (name, value) = adapter::auth(&app.package, &app.header, key.expose());
    let got = Client::new().timeout(HTTP_TIMEOUT).header(name, value).get(&url).and_then(|r| r.ok()).map(|r| r.text());
    match got {
        Ok(text) => {
            said.failed.remove(&app.package);
            Some(text)
        }
        Err(e) => {
            let why = match e {
                HttpError::TlsUnsupported => format!("{} is at an https address and the SDK client speaks plain http only (TlsUnsupported): not polled", app.package),
                e => format!("{} did not answer: {e}", app.package),
            };
            if said.failed.get(&app.package) != Some(&why) {
                log(ctx, LogLevel::Warn, &format!("poller: {why}"));
                said.failed.insert(app.package.clone(), why);
            }
            None
        }
    }
}

/// A finished playback: count it in the monthly rollup and write the event (the core does both; the rollup only for a metric kind of this package).
fn record(ctx: &dyn Ctx, f: &Finished) {
    let user = user_name(&f.user);
    let title = clean(&f.title, 120);
    let mut payload = Map::new();
    payload.insert("minutes".into(), json!(f.minutes));
    if !title.is_empty() {
        payload.insert("title".into(), json!(title));
    }
    if let Err(e) = ctx.emit(&Event::new(SESSION_KIND, user.as_str()).text("Playback finished").payload(payload)) {
        log(ctx, LogLevel::Warn, &format!("session of {user} not written: {e}"));
    }
    if let Err(e) = ctx.rollup(SESSION_KIND, &user, 1.0, f64::from(f.minutes)) {
        log(ctx, LogLevel::Warn, &format!("session of {user} not counted: {e}"));
    }
}

fn playing_json(p: &[Playing]) -> Value {
    json!({"sessions": p.iter().map(|s| json!({"app": s.app, "user": s.user, "title": s.title})).collect::<Vec<_>>()})
}

/// The poller says once which apps it polls and why it skips the others (the rows of the integrations do not change while the process runs).
fn announce(ctx: &dyn Ctx, apps: &[App], why: &str) {
    let names = apps.iter().map(|a| a.package.as_str()).collect::<Vec<_>>().join(", ");
    let line = match (apps.is_empty(), why.is_empty()) {
        (_, true) => format!("poller: polling {names}"),
        (true, false) => format!("poller: {why}"),
        (false, false) => format!("poller: polling {names} (not polled: {why})"),
    };
    log(ctx, if why.is_empty() { LogLevel::Info } else { LogLevel::Warn }, &line);
}

/// The lock of the health record; a poisoned lock still holds a usable record.
fn lock(health: &Mutex<Health>) -> MutexGuard<'_, Health> {
    health.lock().unwrap_or_else(|e| e.into_inner())
}

/// The polling loop of the worker thread.
fn worker(ctx: Arc<dyn Ctx>, health: Arc<Mutex<Health>>, state_dir: PathBuf, interval: f64, min_seconds: f64) {
    let mut poller = Poller::new(state_dir, min_seconds);
    let mut said = Said::default();
    let mut last_playing: Option<Vec<Playing>> = None;
    let (apps, why) = parse_apps(ctx.integrations());
    announce(ctx.as_ref(), &apps, &why);
    loop {
        let playing = poller.poll(&apps, now_secs(), &mut |a| fetch(ctx.as_ref(), &mut said, a), &mut |f| record(ctx.as_ref(), f));
        if last_playing.as_ref() != Some(&playing) && ctx.snapshot("now-playing", playing_json(&playing)).is_ok() {
            last_playing = Some(playing);
        }
        *lock(&health) = Health::ok();
        thread::sleep(Duration::from_secs_f64(interval));
    }
}

/// The state folder: the test knob, else $STATE_DIRECTORY (set by systemd; /var/lib/hs-ext/media-hub inside the unit, where /var/lib/hs is empty).
/// Never /var/lib/hs/media-hub: it does not exist in the unit. Several folders are joined by ':'; the first one is ours.
fn state_dir_from(knob: Option<String>, systemd: Option<String>) -> Result<PathBuf, String> {
    let pick = |v: Option<String>| v.and_then(|v| v.split(':').next().map(str::to_string)).filter(|v| !v.is_empty());
    pick(knob).or_else(|| pick(systemd)).map(PathBuf::from).ok_or_else(|| "STATE_DIRECTORY is not set: the state folder of media-hub is unknown".to_string())
}

/// Starts `job` on a thread that waits until the returned sender sends. The SDK writes `ready` only after `start` has returned, and the core fails
/// a service that writes anything before it (`protocol_error`, hobnix/core#1353). Since 0.14 the SDK holds such a line back, up to a limit; the
/// poller still waits for the first `tick`, which comes after `ready` and sends, so it does nothing before that.
fn after_ready(job: impl FnOnce() + Send + 'static) -> mpsc::Sender<()> {
    let (go, wait) = mpsc::channel();
    thread::spawn(move || {
        if wait.recv().is_ok() {
            job();
        }
    });
    go
}

struct Hub {
    health: Arc<Mutex<Health>>,
    /// The poller's start signal, until the first `tick` has sent it.
    go: Option<mpsc::Sender<()>>,
}

impl Service for Hub {
    fn start(&mut self, _init: &Init, ctx: &dyn Ctx) -> Result<(), Error> {
        let interval = env_f64("HS_MEDIA_POLL_SECONDS", 30.0);
        if interval > 0.0 {
            let state_dir = state_dir_from(std::env::var("HS_MEDIA_STATE_DIR").ok(), std::env::var("STATE_DIRECTORY").ok())?;
            let (ctx, health, min) = (ctx.shared(), self.health.clone(), env_f64("HS_MEDIA_MIN_SECONDS", 60.0));
            self.go = Some(after_ready(move || worker(ctx, health, state_dir, interval.max(0.05), min)));
        }
        Ok(())
    }

    fn tick(&mut self, _ctx: &dyn Ctx) -> Health {
        if let Some(go) = self.go.take() {
            let _ = go.send(());
        }
        lock(&self.health).clone()
    }
}

fn main() -> ExitCode {
    run(Hub { health: Arc::new(Mutex::new(Health::ok())), go: None })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_poller_waits_for_the_signal_that_follows_ready() {
        let (done, seen) = mpsc::channel();
        let go = after_ready(move || done.send(()).expect("send"));
        assert!(seen.recv_timeout(Duration::from_millis(200)).is_err(), "nothing runs before the signal");
        go.send(()).expect("signal");
        seen.recv_timeout(Duration::from_secs(5)).expect("runs after the signal");
    }

    #[test]
    fn state_dir_comes_from_the_unit_and_never_from_var_lib_hs() {
        assert_eq!(state_dir_from(None, Some("/var/lib/hs-ext/media-hub".into())).unwrap(), PathBuf::from("/var/lib/hs-ext/media-hub"));
        assert_eq!(state_dir_from(None, Some("/a:/b".into())).unwrap(), PathBuf::from("/a"));
        assert_eq!(state_dir_from(Some("/t".into()), Some("/a".into())).unwrap(), PathBuf::from("/t"));
        assert!(state_dir_from(None, None).unwrap_err().contains("STATE_DIRECTORY"));
        assert!(state_dir_from(Some(String::new()), Some(String::new())).is_err());
    }
    use hobnix_pkg::integrations::Integration;
    use hobnix_pkg::testing::{Call, FakeCtx};

    fn row(package: &str, url: &str) -> Integration {
        let mut row = Integration::new(package, "media", "recipe");
        row.api_url = Some(url.into());
        row
    }

    #[test]
    fn a_provider_without_a_key_is_named_once_and_not_asked() {
        let ctx = FakeCtx::new().with_integrations(vec![row("jellyfin", "http://127.0.0.1:1")]);
        let (apps, why) = parse_apps(ctx.integrations());
        assert!(why.is_empty());
        let mut said = Said::default();
        assert_eq!(fetch(&ctx, &mut said, &apps[0]), None);
        assert_eq!(fetch(&ctx, &mut said, &apps[0]), None);
        let warns = ctx.calls().into_iter().filter(|c| matches!(c, Call::Log(LogLevel::Warn, t) if t.contains("no key handed over for jellyfin")));
        assert_eq!(warns.count(), 1);
    }

    #[test]
    fn the_announcement_names_the_apps_and_the_reason() {
        let ctx = FakeCtx::new().with_integrations(vec![row("jellyfin", "http://x"), row("radarr", "http://y")]);
        let (apps, why) = parse_apps(ctx.integrations());
        announce(&ctx, &apps, &why);
        assert_eq!(ctx.calls(), [Call::Log(LogLevel::Warn, "poller: polling jellyfin (not polled: radarr has no adapter)".into())]);
    }
}
