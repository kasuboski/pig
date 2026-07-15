//// Shared config for pig_proxy integration tests.
////
//// These start the real proxy (full supervisor tree + mist server) and, for
//// the forwarding test, hit a live OpenAI-compatible upstream. All
//// integration tests import from here.

import envoy
import filepath
import gleam/int
import gleam/result
import simplifile

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

/// Whether the proxy is configured for ChatGPT/Codex OAuth (the default
/// target authenticates as Codex). Set via OPENAI_COMPAT_CODEX=1 or by
/// providing OPENAI_COMPAT_CODEX_TOKEN.
pub fn is_codex() -> Bool {
  case envoy.get("OPENAI_COMPAT_CODEX") {
    Ok("1") -> True
    Ok("true") -> True
    _ ->
      case envoy.get("OPENAI_COMPAT_CODEX_TOKEN") {
        Ok(_) -> True
        _ -> False
      }
  }
}

/// Whether Codex credentials are available to the proxy: either a seed token
/// in the environment or a persisted credential file at PIG_CODEX_AUTH_PATH
/// (default `~/.pig/codex_auth.json`, populated by `gleam run -m
/// pig_proxy/codex_login`). Used by the Codex test to skip with a clear
/// message rather than failing on a 401.
pub fn has_codex_credentials() -> Bool {
  case envoy.get("OPENAI_COMPAT_CODEX_TOKEN") {
    Ok(_) -> True
    _ ->
      case envoy.get("PIG_CODEX_AUTH_PATH") {
        Ok(_) -> True
        _ ->
          case envoy.get("HOME") {
            Ok(home) -> {
              let path = filepath.join(home, ".pig/codex_auth.json")
              case simplifile.is_file(path) {
                Ok(True) -> True
                _ -> False
              }
            }
            Error(_) -> False
          }
      }
  }
}
