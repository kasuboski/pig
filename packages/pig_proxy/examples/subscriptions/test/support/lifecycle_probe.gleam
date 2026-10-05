//// Isolated-VM probe for shutdown failures using the production lifecycle.

import gleam/erlang/process
import gleam/io
import subscriptions/lifecycle

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

/// Run a bounded failure scenario in a disposable BEAM VM.
pub fn main(scenario: Int) -> Nil {
  let cleanup = fn() {
    case scenario {
      3 -> process.sleep_forever()
      5 -> panic as "private-lifecycle-marker"
      _ -> Nil
    }
  }
  let sdk_stop = fn() {
    case scenario {
      1 -> {
        process.kill(process.self())
        Ok(Nil)
      }
      2 -> {
        process.sleep_forever()
        Ok(Nil)
      }
      4 -> panic as "private-lifecycle-marker"
      6 -> Error(Nil)
      _ -> Ok(Nil)
    }
  }
  case lifecycle.shutdown(cleanup, sdk_stop, 200, 50) {
    Ok(Nil) -> {
      // Stay alive past the configured deadline to detect an uncancelled watchdog.
      process.sleep(400)
      io.println("lifecycle shutdown completed")
      halt(0)
    }
    Error(_) -> {
      io.println("lifecycle shutdown failed; trace delivery is not guaranteed")
      halt(1)
    }
  }
}
