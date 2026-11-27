//! The calls to GitHub. In the trial: one unauthenticated request that shows that the static program can speak HTTPS.

use std::time::Duration;

/// Says how many requests are left for this address; it needs no login and does not count against the limit.
const RATE_LIMIT_URL: &str = "https://api.github.com/rate_limit";
/// GitHub refuses a request without a user agent. A fixed name: nothing about the server or its owner.
const USER_AGENT: &str = concat!("hobnix-autopilot/", env!("CARGO_PKG_VERSION"));
const TIMEOUT: Duration = Duration::from_secs(15);

/// The HTTP status of GitHub's rate limit endpoint, or why there is no answer.
pub fn rate_limit_status() -> Result<u16, String> {
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(TIMEOUT))
        .https_only(true)
        .http_status_as_error(false)
        .user_agent(USER_AGENT)
        .build()
        .into();
    agent
        .get(RATE_LIMIT_URL)
        .call()
        .map(|response| response.status().as_u16())
        .map_err(|e| e.to_string())
}
