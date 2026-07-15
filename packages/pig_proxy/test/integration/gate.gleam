//// Integration test gate helper.

import gleam/erlang/process
import gleam/int
import gleam/io
import integration/config
import pig_proxy/hackney

const readiness_attempts = 20
const readiness_backoff_ms = 50

/// If the integration gate is not set, print a skip message and return
/// `True`. Callers should return early from their test when this returns
/// `True`.
pub fn skip_unless_enabled() -> Bool {
  case config.should_run() {
    Ok(_) -> False
    Error(_) -> {
      io.println(
        "[SKIP] Integration tests not enabled. Set "
        <> config.run_env
        <> "=1 to run.",
      )
      True
    }
  }
}

/// Poll the proxy health endpoint with a bounded short backoff until it is
/// ready to accept the test's actual request.
pub fn wait_until_ready(port: Int) -> Bool {
  wait_until_ready_attempt(port, readiness_attempts)
}

fn wait_until_ready_attempt(port: Int, attempts_left: Int) -> Bool {
  let url = "http://localhost:" <> int.to_string(port) <> "/health"
  case hackney.sync_request("GET", url, [], "", 1_000) {
    hackney.OkResponse(status: 200, ..) -> True
    _ ->
      case attempts_left <= 0 {
        True -> False
        False -> {
          process.sleep(readiness_backoff_ms)
          wait_until_ready_attempt(port, attempts_left - 1)
        }
      }
  }
}
