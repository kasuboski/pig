//// Shared config for pig_proxy integration tests.
////
//// These start the real proxy (full supervisor tree + mist server) and, for
//// the forwarding test, hit a live OpenAI-compatible upstream. All
//// integration tests import from here.

import envoy
import gleam/int
import gleam/result

/// Gating variable — must be set to run integration tests. Reused across the
/// monorepo (pig, pig_protocol, pig_proxy) so a single opt-in runs them all.
pub const run_env = "PIG_RUN_INTEGRATION"

/// Check whether integration tests should run. `Ok(Nil)` if the gate is open.
pub fn should_run() -> Result(Nil, Nil) {
  case envoy.get(run_env) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(Nil)
  }
}

/// The model name used for the forwarding test. Defaults to a small local
/// model; override with OPENAI_COMPAT_MODEL.
pub fn model() -> String {
  envoy.get("OPENAI_COMPAT_MODEL") |> result.unwrap("gemopuse4b")
}

/// Base port the integration proxy listens on. The forwarding test uses
/// `base_port() + 1` so the two server-starting tests never collide on the
/// same port (a mist listener outlives the test function that started it).
pub fn base_port() -> Int {
  case envoy.get("PIG_PROXY_INTEGRATION_PORT") {
    Ok(s) -> int.parse(s) |> result.unwrap(8087)
    Error(_) -> 8087
  }
}
