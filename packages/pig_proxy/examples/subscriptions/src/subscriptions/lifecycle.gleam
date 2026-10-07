//// Gleam shutdown policy and owner-bound cleanup with bounded SDK termination.

import exception
import gleam/erlang/process
import gleam/int
import gleam/io

/// Maximum duration for the complete owner-side cleanup.
pub const shutdown_timeout_ms = 30_000

/// Maximum duration for the SDK's blocking stop operation.
pub const sdk_stop_timeout_ms = 15_000

/// Failures never carry exception values or captured configuration.
pub type ShutdownError {
  CleanupFailed
  SdkStopFailed
  SdkStopTimedOut
}

/// Observable SDK-stop outcomes: an exit is not a successful result.
pub type SdkStopOutcome {
  Completed(Result(Nil, Nil))
  WorkerExited
}

/// Classify a completion or worker death without exposing foreign error terms.
pub fn sdk_stop_result(outcome: SdkStopOutcome) -> Result(Nil, ShutdownError) {
  case outcome {
    Completed(Ok(Nil)) -> Ok(Nil)
    Completed(Error(Nil)) | WorkerExited -> Error(SdkStopFailed)
  }
}

/// Run cleanup on its owner, then bound the SDK stop on an isolated worker.
/// An independent watchdog halts the VM if owner-side cleanup cannot return.
pub fn shutdown(
  cleanup: fn() -> Nil,
  sdk_stop: fn() -> Result(Nil, Nil),
  overall_timeout: Int,
  sdk_timeout: Int,
) -> Result(Nil, ShutdownError) {
  let owner = process.self()
  let ready = process.new_subject()
  let _watchdog =
    process.spawn_unlinked(fn() {
      let complete = process.new_subject()
      let owner_monitor = process.monitor(owner)
      process.send(ready, complete)
      let selector =
        process.new_selector()
        |> process.select(complete)
        |> process.select_specific_monitor(owner_monitor, fn(_) { Nil })
      case process.selector_receive(selector, overall_timeout) {
        Ok(Nil) -> process.demonitor_process(owner_monitor)
        Error(_) -> {
          io.println_error(
            "subscriptions host shutdown timed out; trace delivery is not guaranteed",
          )
          halt(1)
        }
      }
    })
  let complete = process.receive_forever(ready)
  let outcome = case exception.rescue(cleanup) {
    Error(_) -> Error(CleanupFailed)
    Ok(Nil) -> stop_sdk(sdk_stop, sdk_timeout)
  }
  process.send(complete, Nil)
  outcome
}

fn stop_sdk(
  stop: fn() -> Result(Nil, Nil),
  timeout: Int,
) -> Result(Nil, ShutdownError) {
  let deadline = monotonic_time(Millisecond) + timeout
  let ready = process.new_subject()
  let replies = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      let begin = process.new_subject()
      process.send(ready, begin)
      let _ = process.receive_forever(begin)
      let result = case exception.rescue(stop) {
        Ok(result) -> result
        Error(_) -> Error(Nil)
      }
      process.send(replies, Completed(result))
    })
  let monitor = process.monitor(worker)
  let selector =
    process.new_selector()
    |> process.select(replies)
    |> process.select_specific_monitor(monitor, fn(_) { WorkerExited })
  // The worker cannot stop before its monitor exists, even for immediate callbacks.
  let startup =
    process.new_selector()
    |> process.select_map(ready, Ok)
    |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
  let outcome = case process.selector_receive(startup, remaining(deadline)) {
    Ok(Ok(begin)) -> {
      process.send(begin, Nil)
      case process.selector_receive(selector, remaining(deadline)) {
        Ok(reply) -> sdk_stop_result(reply)
        Error(_) -> {
          process.kill(worker)
          Error(SdkStopTimedOut)
        }
      }
    }
    Ok(Error(Nil)) -> Error(SdkStopFailed)
    Error(_) -> {
      process.kill(worker)
      Error(SdkStopTimedOut)
    }
  }
  process.demonitor_process(monitor)
  outcome
}

type TimeUnit {
  Millisecond
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: TimeUnit) -> Int

fn remaining(deadline: Int) -> Int {
  int.max(0, deadline - monotonic_time(Millisecond))
}

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil
