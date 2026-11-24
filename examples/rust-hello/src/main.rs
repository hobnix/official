//! EXAMPLE command extension (see Cargo.toml): `greet [name]`, the smallest use of the core's SDK.
use hobnix_ext_sdk::command::{run, Failure, Request, Success};
use hobnix_ext_sdk::Ctx;
use serde_json::json;
use std::process::ExitCode;

fn handle(req: &Request, _ctx: &dyn Ctx) -> Result<Success, Failure> {
    match req.words().as_slice() {
        ["greet"] => {
            let name = req.argv.first().map(String::as_str).unwrap_or("world");
            let greeting = format!("hello {name}");
            Ok(Success::data(json!({ "greeting": greeting })).with_text(greeting))
        }
        _ => Err(Failure::not_found("no such command")),
    }
}

fn main() -> ExitCode {
    run(handle)
}
