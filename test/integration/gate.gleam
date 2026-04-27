//// Integration test gate helper.

import gleam/io
import integration/config

/// If the integration gate is not set, print a skip message and
/// return True. Callers should return early from their test when
/// this returns True.
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
