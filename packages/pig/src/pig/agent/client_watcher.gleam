//// Explicit client-owner monitoring for transient run streams.

import gleam/erlang/process
import gleam/option

/// A cancellable watch on the process responsible for a run's client.
pub opaque type Watch {
  Watch(pid: process.Pid)
}

type WatchEvent {
  ClientDown
  RuntimeDown
}

/// Notify the runtime if `client` exits while the runtime still owns the run.
pub fn start(client: process.Pid, notify: fn() -> Nil) -> Watch {
  let runtime = process.self()
  let pid =
    process.spawn_unlinked(fn() {
      case process.is_alive(client) {
        False -> notify()
        True -> {
          let client_monitor = process.monitor(client)
          let runtime_monitor = process.monitor(runtime)
          let selector =
            process.new_selector()
            |> process.select_specific_monitor(client_monitor, fn(_) {
              ClientDown
            })
            |> process.select_specific_monitor(runtime_monitor, fn(_) {
              RuntimeDown
            })
          case process.selector_receive_forever(selector) {
            ClientDown -> notify()
            RuntimeDown -> Nil
          }
        }
      }
    })
  Watch(pid:)
}

/// Stop watching after the run reaches terminality.
pub fn stop(watch: Watch) -> Nil {
  process.kill(watch.pid)
}

@internal
pub fn stop_option(watcher: option.Option(Watch)) -> Nil {
  case watcher {
    option.Some(watch) -> stop(watch)
    option.None -> Nil
  }
}
