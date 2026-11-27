//! `hs ext autopilot`: the packaging trial of the capability autopilot (hobnix/core#1374). Nothing is run for an issue yet.
//! The commands and the rows of commands.tsv come from the attributes below; `--commands-tsv` prints the rows.

mod github;

use std::process::ExitCode;

use hobnix_pkg_command::{Commands, Ctx, Failure, Success, command, commands};
use serde_json::{Value, json};

fn status_data() -> Value {
    json!({ "state": "trial", "jobs": 0, "version": env!("CARGO_PKG_VERSION") })
}

#[command(
    name = "status",
    reads,
    help = "show what autopilot is doing",
    help_de = "zeigt, was Autopilot tut",
    sys = "the state of autopilot, as key and value"
)]
fn status(_ctx: &dyn Ctx) -> Result<Success, Failure> {
    Ok(
        Success::data(status_data())
            .with_text("Autopilot is a trial: it does not run any job yet."),
    )
}

#[command(
    name = "github",
    reads,
    help = "check that GitHub answers over HTTPS",
    help_de = "prüft, ob GitHub über HTTPS antwortet",
    timeout = 30
)]
fn github_check(_ctx: &dyn Ctx) -> Result<Success, Failure> {
    let code = github::rate_limit_status()
        .map_err(|e| Failure::failed(format!("GitHub did not answer: {e}")))?;
    if code != 200 {
        return Err(Failure::failed(format!(
            "GitHub answered with status {code}"
        )));
    }
    Ok(
        Success::data(json!({ "github": "reachable", "status": code }))
            .with_text("GitHub answers over HTTPS."),
    )
}

fn table() -> Commands {
    commands!(
        package = "autopilot",
        script = "@/bin/autopilot",
        status,
        github_check
    )
}

fn main() -> ExitCode {
    // for the author, never used by the core (it starts the program without arguments): the rows commands.tsv must hold
    if std::env::args().nth(1).as_deref() == Some("--commands-tsv") {
        let rows = table().tsv();
        return match std::io::Write::write_all(&mut std::io::stdout(), rows.as_bytes()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(_) => ExitCode::FAILURE,
        };
    }
    table().run()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commands_tsv_matches_the_code() {
        assert!(
            table().check(include_str!("../commands.tsv")).is_ok(),
            "run the program with --commands-tsv"
        );
    }

    #[test]
    fn status_runs_no_job() {
        assert_eq!(status_data()["jobs"], 0);
    }
}
