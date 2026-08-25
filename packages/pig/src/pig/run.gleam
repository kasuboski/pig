//// Transient, caller-owned event streams for one complete agent run.

import gleam/bit_array
import gleam/crypto
import gleam/erlang/process
import gleam/json.{type Json}
import pig/provider.{type InferenceResult}
import pig/run_error
import pig/tool.{type ToolError}
import pig_protocol/error.{type AiError}
import pig_protocol/inference.{type InferenceDelta}
import pig_protocol/message.{type Message, type ToolCall}

/// Events emitted for one accepted run.
///
/// Deltas are transient and only appear here. Every started inference and tool
/// operation has one matching finished event, and every run has one terminal
/// `Completed`, `Failed`, or `Cancelled` event.
pub type RunEvent {
  RunStarted
  InferenceStarted(round: Int)
  InferenceDelta(round: Int, delta: InferenceDelta)
  InferenceFinished(round: Int, result: Result(InferenceResult, AiError))
  ToolStarted(round: Int, call: ToolCall)
  ToolFinished(round: Int, call: ToolCall, result: Result(Json, ToolError))
  ToolBlocked(round: Int, call: ToolCall, reason: String)
  Completed(result: InferenceResult)
  Failed(error: run_error.RunError)
  Cancelled(reason: run_error.CancelReason)
}

/// Opaque handle for cancelling or watching one accepted run.
pub opaque type Run {
  Run(
    id: String,
    runtime_owner: process.Pid,
    terminal: process.Subject(RunEvent),
    cancel: fn(run_error.CancelReason) -> Nil,
    watch_client: fn(process.Pid) -> Nil,
  )
}

/// Cancel a run. Repeated calls and calls after terminality are harmless.
pub fn cancel(run: Run, reason: run_error.CancelReason) -> Nil {
  run.cancel(reason)
}

/// Replace the process watched as this run's client owner.
///
/// If that process exits while the run is active, the runtime cancels the run
/// with `ClientDisconnected`.
pub fn watch_client(run: Run, owner: process.Pid) -> Nil {
  run.watch_client(owner)
}

@internal
pub fn new(
  id: String,
  runtime_owner: process.Pid,
  terminal: process.Subject(RunEvent),
  cancel: fn(run_error.CancelReason) -> Nil,
  watch_client: fn(process.Pid) -> Nil,
) -> Run {
  Run(id:, runtime_owner:, terminal:, cancel:, watch_client:)
}

@internal
pub fn publish_terminal(run: Run, event: RunEvent) -> Nil {
  process.send(run.terminal, event)
}

@internal
pub fn id(run: Run) -> String {
  run.id
}

pub fn runtime_owner(run: Run) -> process.Pid {
  run.runtime_owner
}

@internal
pub fn fresh_id() -> String {
  "run-" <> bit_array.base64_url_encode(crypto.strong_random_bytes(16), False)
}

type CollectMessage {
  TerminalEvent(RunEvent)
  Deadline
  RuntimeDown
}

/// Collect a run stream into the final message. The timeout actively cancels.
@internal
pub fn collect(
  run: Run,
  _sink: process.Subject(RunEvent),
  timeout_ms: Int,
  runtime_owner: process.Pid,
) -> Result(Message, run_error.RunError) {
  let deadline = process.new_subject()
  let timer = process.send_after(deadline, timeout_ms, Nil)
  let runtime_monitor = process.monitor(runtime_owner)
  let selector =
    process.new_selector()
    |> process.select_map(run.terminal, TerminalEvent)
    |> process.select_map(deadline, fn(_) { Deadline })
    |> process.select_specific_monitor(runtime_monitor, fn(_) { RuntimeDown })
  collect_events(run, selector, timer, runtime_monitor)
}

fn collect_events(
  run: Run,
  selector: process.Selector(CollectMessage),
  timer: process.Timer,
  runtime_monitor: process.Monitor,
) -> Result(Message, run_error.RunError) {
  case process.selector_receive_forever(selector) {
    RuntimeDown -> {
      let _ = process.cancel_timer(timer)
      case process.receive(run.terminal, 0) {
        Ok(event) -> terminal_result(event)
        Error(Nil) -> Error(run_error.RuntimeUnavailable)
      }
    }
    Deadline ->
      case process.receive(run.terminal, 0) {
        Ok(event) -> {
          let _ = process.cancel_timer(timer)
          process.demonitor_process(runtime_monitor)
          terminal_result(event)
        }
        Error(Nil) -> {
          process.demonitor_process(runtime_monitor)
          cancel(run, run_error.DeadlineExceeded)
          Error(run_error.Cancelled(run_error.DeadlineExceeded))
        }
      }
    TerminalEvent(event) -> {
      let _ = process.cancel_timer(timer)
      process.demonitor_process(runtime_monitor)
      terminal_result(event)
    }
  }
}

fn terminal_result(event: RunEvent) -> Result(Message, run_error.RunError) {
  case event {
    Completed(result) -> Ok(result.message)
    Failed(error) -> Error(error)
    Cancelled(reason) -> Error(run_error.Cancelled(reason))
    _ ->
      Error(run_error.Runtime(
        "run terminal channel received a non-terminal event",
      ))
  }
}
