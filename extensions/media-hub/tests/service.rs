//! The real media-svc program against a tiny local http server that serves the fixtures of tests/fixtures/media-hub, over the service protocol
//! (JSON lines on stdin and stdout). Every app answer is a hand-made fixture: the adapters are UNVERIFIED against a real Jellyfin or Plex.
#![cfg(unix)]
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{channel, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

fn fixture(name: &str) -> String {
    std::fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/media-hub").join(name)).unwrap()
}

fn scratch(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("media-svc-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A server that answers every GET with the current body and keeps the request heads it saw.
struct Fake {
    port: u16,
    body: Arc<Mutex<String>>,
    heads: Arc<Mutex<Vec<String>>>,
}

fn fake(body: &str) -> Fake {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    let (body, heads) = (Arc::new(Mutex::new(body.to_string())), Arc::new(Mutex::new(Vec::new())));
    let (b, h) = (body.clone(), heads.clone());
    thread::spawn(move || {
        for s in l.incoming().flatten() {
            let mut s = s;
            // a client that connects and says nothing must not block the next one for ever
            let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
            let _ = s.set_write_timeout(Some(Duration::from_secs(5)));
            let mut head = Vec::new();
            let mut byte = [0u8; 1];
            while !head.ends_with(b"\r\n\r\n") && s.read(&mut byte).unwrap_or(0) == 1 {
                head.push(byte[0]);
            }
            h.lock().unwrap().push(String::from_utf8_lossy(&head).into_owned());
            let body = b.lock().unwrap().clone();
            let _ = write!(s, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        }
    });
    Fake { port, body, heads }
}

struct Svc {
    child: Child,
    stdin: ChildStdin,
    rx: Receiver<Value>,
    seen: Vec<Value>,
}

/// Hard limit for every wait on the service: it fails with the messages seen so far instead of waiting for ever.
const DEADLINE: Duration = Duration::from_secs(20);

impl Drop for Svc {
    fn drop(&mut self) {
        // the child never outlives the test, whether it passed, failed or timed out
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Svc {
    fn start(env: &[(&str, String)], integrations: Value) -> Svc {
        let mut c = Command::new(env!("CARGO_BIN_EXE_media-svc"));
        c.env_clear().stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit());
        for (k, v) in env {
            c.env(k, v);
        }
        let mut child = c.spawn().unwrap();
        let mut stdin = child.stdin.take().unwrap();
        let out = child.stdout.take().unwrap();
        let (tx, rx) = channel();
        thread::spawn(move || {
            for l in BufReader::new(out).lines().map_while(Result::ok) {
                if tx.send(serde_json::from_str(&l).unwrap_or_else(|_| panic!("stdout carries only protocol lines, got: {l}"))).is_err() {
                    break;
                }
            }
        });
        writeln!(stdin, "{}", json!({"v":1,"type":"init","name":"media-hub","lang":"en","subscribe":[],"health_interval":1,"integrations":integrations})).unwrap();
        let mut svc = Svc { child, stdin, rx, seen: Vec::new() };
        svc.wait(|m| m["type"] == "ready");
        svc
    }

    /// The next message that matches, within DEADLINE in total (the service sends a snapshot every poll, so a per-message timeout would never fire);
    /// every message read is kept in `seen`.
    fn wait(&mut self, want: impl Fn(&Value) -> bool) -> Value {
        let end = Instant::now() + DEADLINE;
        loop {
            let left = end.saturating_duration_since(Instant::now());
            let m = self.rx.recv_timeout(left).unwrap_or_else(|_| panic!("no matching message within {DEADLINE:?}; seen: {:?}", self.seen));
            self.seen.push(m.clone());
            if want(&m) {
                return m;
            }
        }
    }

    fn send(&mut self, v: Value) {
        // a service that already exited closes the pipe: that is for the waits to report, not a panic here
        let _ = writeln!(self.stdin, "{v}");
    }

    fn stop(mut self) -> Vec<Value> {
        self.send(json!({"v":1,"type":"shutdown"}));
        let end = Instant::now() + DEADLINE;
        let status = loop {
            if let Some(st) = self.child.try_wait().unwrap() {
                break st;
            }
            assert!(Instant::now() < end, "the service did not exit within {DEADLINE:?} of shutdown; seen: {:?}", self.seen);
            thread::sleep(Duration::from_millis(20));
        };
        assert!(status.success(), "exit {status}");
        while let Ok(m) = self.rx.recv_timeout(Duration::from_millis(200)) {
            self.seen.push(m);
        }
        std::mem::take(&mut self.seen)
    }
}

fn is_log(text: &'static str) -> impl Fn(&Value) -> bool {
    move |m| m["type"] == "log" && m["text"].as_str().is_some_and(|t| t.contains(text))
}

/// One entry of `init.integrations` as the core sends it: no key, no key file.
fn row(package: &str, url: Option<String>, extras: Value, header: Option<&str>) -> Value {
    json!({"package": package, "integration": "media", "source": "recipe", "api_url": url, "extras": extras, "key_header": header})
}

fn http(port: u16) -> Option<String> {
    Some(format!("http://127.0.0.1:{port}"))
}

fn env_for(dir: &Path, creds: &[(&str, &str)], poll: &str) -> Vec<(&'static str, String)> {
    let cdir = dir.join("creds");
    std::fs::create_dir_all(&cdir).unwrap();
    for (n, k) in creds {
        std::fs::write(cdir.join(n), format!("{k}\n")).unwrap();
    }
    vec![
        ("CREDENTIALS_DIRECTORY", cdir.display().to_string()),
        ("HS_MEDIA_STATE_DIR", dir.join("state").display().to_string()),
        ("HS_MEDIA_POLL_SECONDS", poll.into()),
        ("HS_MEDIA_MIN_SECONDS", "0".into()),
    ]
}

#[test]
fn polls_jellyfin_with_its_own_key_and_counts_a_finished_playback() {
    let dir = scratch("poll");
    let jf = fake(&fixture("jellyfin-sessions.json"));
    let rows = json!([
        row("jellyfin", http(jf.port), json!({}), Some("X-Emby-Token")),
        row("radarr", Some("http://127.0.0.1:1".into()), json!({"kind": "movies"}), Some("X-Api-Key")),
        row("plex", Some("https://plex.lan:32400".into()), json!({}), None),
    ]);
    let creds = [("integration-media-jellyfin", "JELLY-KEY"), ("integration-media-plex", "PLEX-KEY")];
    let mut svc = Svc::start(&env_for(&dir, &creds, "0.2"), rows);
    let note = svc.wait(is_log("radarr has no adapter"));
    let t = note["text"].as_str().unwrap();
    assert!(t.contains("polling jellyfin") && t.contains("plex is at an https address") && t.contains("TlsUnsupported"), "{t}");
    let snap = svc.wait(|m| m["type"] == "snapshot" && m["data"]["sessions"].as_array().is_some_and(|s| s.len() == 2));
    assert_eq!(snap["topic"], "now-playing");
    assert_eq!(snap["data"]["sessions"][0], json!({"app": "jellyfin", "user": "anna", "title": "Dune"}));
    // the playback ends: counted once, for anna and for carl_smith
    *jf.body.lock().unwrap() = "[]".into();
    let emit = svc.wait(|m| m["type"] == "emit" && m["subject"] == "anna");
    assert_eq!(emit["kind"], "pkg.media-hub.session-completed");
    assert_eq!(emit["payload"], json!({"minutes": 1, "title": "Dune"}));
    let roll = svc.wait(|m| m["type"] == "rollup" && m["user"] == "anna");
    assert_eq!((roll["kind"].as_str(), roll["n"].as_f64(), roll["sum"].as_f64()), (Some("pkg.media-hub.session-completed"), Some(1.0), Some(1.0)));
    svc.wait(|m| m["type"] == "rollup" && m["user"] == "carl_smith");
    svc.wait(|m| m["type"] == "snapshot" && m["data"]["sessions"].as_array().is_some_and(|s| s.is_empty()));
    let seen = svc.stop();
    let heads = jf.heads.lock().unwrap();
    assert!(heads.iter().all(|h| h.starts_with("GET /Sessions HTTP/1.1")), "{heads:?}");
    assert!(heads.iter().all(|h| h.contains("Authorization: MediaBrowser Token=\"JELLY-KEY\"\r\n") && !h.contains("X-Emby-Token") && !h.contains("PLEX-KEY")), "the key of jellyfin goes to jellyfin only");
    let all = serde_json::to_string(&seen).unwrap();
    assert!(!all.contains("JELLY-KEY") && !all.contains("PLEX-KEY"), "a key is never written to the protocol");
    let w = std::fs::read_to_string(dir.join("state/watched.tsv")).unwrap();
    assert!(w.contains("Dune.mkv\t/media/movies/Dune (2021)"), "{w}");
    let health = seen.iter().rfind(|m| m["type"] == "health").unwrap();
    assert_eq!(health["ok"], true);
}

#[test]
fn polls_plex_in_its_own_header_next_to_jellyfin() {
    let dir = scratch("plex");
    let (jf, px) = (fake("[]"), fake(&fixture("plex-sessions.json")));
    let rows = json!([row("jellyfin", http(jf.port), json!({}), None), row("plex", http(px.port), json!({}), None)]);
    let creds = [("integration-media-jellyfin", "JK"), ("integration-media-plex", "PK")];
    let mut svc = Svc::start(&env_for(&dir, &creds, "0.2"), rows);
    let snap = svc.wait(|m| m["type"] == "snapshot" && m["data"]["sessions"].as_array().is_some_and(|s| !s.is_empty()));
    assert_eq!(snap["data"]["sessions"][0], json!({"app": "plex", "user": "dora", "title": "Arrival"}));
    svc.stop();
    let (j, p) = (jf.heads.lock().unwrap(), px.heads.lock().unwrap());
    assert!(j[0].starts_with("GET /Sessions ") && j[0].contains("Authorization: MediaBrowser Token=\"JK\"\r\n") && !j[0].contains("PK"), "{j:?}");
    assert!(p[0].starts_with("GET /status/sessions ") && p[0].contains("X-Plex-Token: PK\r\n") && !p[0].contains("JK"), "{p:?}");
}

#[test]
fn a_provider_without_a_key_is_not_asked() {
    let dir = scratch("nokey");
    let jf = fake(&fixture("jellyfin-sessions.json"));
    let rows = json!([row("jellyfin", http(jf.port), json!({}), None)]);
    let mut svc = Svc::start(&env_for(&dir, &[], "0.2"), rows);
    svc.wait(is_log("no key handed over for jellyfin"));
    svc.wait(|m| m["type"] == "snapshot");
    svc.stop();
    assert!(jf.heads.lock().unwrap().is_empty(), "no key, no call");
}

#[test]
fn an_init_without_integrations_polls_nothing() {
    let dir = scratch("none");
    let mut svc = Svc::start(&env_for(&dir, &[], "0.2"), json!([]));
    svc.wait(is_log("no media app found"));
    svc.wait(|m| m["type"] == "snapshot" && m["data"]["sessions"].as_array().is_some_and(|s| s.is_empty()));
    svc.stop();
}

/// Inside the unit systemd sets STATE_DIRECTORY (/var/lib/hs-ext/media-hub) and nothing else names the folder: the list is kept there.
#[test]
fn keeps_watched_tsv_in_state_directory() {
    let dir = scratch("statedir");
    let jf = fake(&fixture("jellyfin-sessions.json"));
    let rows = json!([row("jellyfin", http(jf.port), json!({}), Some("X-Emby-Token"))]);
    let mut env = env_for(&dir, &[("integration-media-jellyfin", "JELLY-KEY")], "0.2");
    env.retain(|(k, _)| *k != "HS_MEDIA_STATE_DIR");
    env.push(("STATE_DIRECTORY", dir.join("unit-state").display().to_string()));
    let mut svc = Svc::start(&env, rows);
    svc.wait(|m| m["type"] == "snapshot" && m["data"]["sessions"].as_array().is_some_and(|s| s.len() == 2));
    *jf.body.lock().unwrap() = "[]".into();
    // the rollup is sent before watched.tsv is written: the snapshot after the poll is the first sign that the file is there
    svc.wait(|m| m["type"] == "snapshot" && m["data"]["sessions"].as_array().is_some_and(|s| s.is_empty()));
    svc.stop();
    let w = std::fs::read_to_string(dir.join("unit-state/watched.tsv")).unwrap();
    assert!(w.contains("Dune.mkv"), "{w}");
}
