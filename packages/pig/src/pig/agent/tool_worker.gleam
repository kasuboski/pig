//// Owned, cancellable execution for one tool call.

import gleam/erlang/process
import gleam/json
import pig/tool
import pig/tool/execution
import pig_protocol/message.{type ToolCall}

/// An owned tool operation. Its execution process is hidden from callers.
pub opaque type Worker {
  Worker(commands: process.Subject(Command))
}

type Command {
  Cancel
}

type SourceMessage {
  Finished(Result(json.Json, tool.ToolError), duration_ms: Int)
}

type CoordinatorMessage {
  Source(SourceMessage)
  CancelRequested
  SourceDown
  OwnerDown
}

/// Start one tool operation and return before its handler executes.
pub fn start(
  registry: tool.ToolRegistry,
  call: ToolCall,
  notify: fn(Result(json.Json, tool.ToolError), Int) -> Nil,
) -> Worker {
  let owner = process.self()
  let ready = process.new_subject()
  let _spawned =
    process.spawn_unlinked(fn() {
      let commands = process.new_subject()
      let source_messages = process.new_subject()
      process.send(ready, commands)
      let started_at = now()
      let source =
        process.spawn_unlinked(fn() {
          let result = execution.execute_tool(registry, call)
          process.send(source_messages, Finished(result, now() - started_at))
          hold_until_released()
        })
      coordinator(
        commands,
        source_messages,
        source,
        process.monitor(source),
        process.monitor(owner),
        started_at,
        notify,
      )
    })
  Worker(commands: process.receive_forever(ready))
}

/// Cancel this operation. Repeated calls are harmless.
pub fn cancel(worker: Worker) -> Nil {
  process.send(worker.commands, Cancel)
}

// Keep the source alive after sending its result so its monitor cannot race the result message and make the coordinator report a duplicate fallback result.
fn hold_until_released() -> Nil {
  let release = process.new_subject()
  process.receive_forever(release)
}

fn coordinator(
  commands: process.Subject(Command),
  source_messages: process.Subject(SourceMessage),
  source: process.Pid,
  source_monitor: process.Monitor,
  owner_monitor: process.Monitor,
  started_at: Int,
  notify: fn(Result(json.Json, tool.ToolError), Int) -> Nil,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(source_messages, Source)
    |> process.select_map(commands, fn(_) { CancelRequested })
    |> process.select_specific_monitor(source_monitor, fn(_) { SourceDown })
    |> process.select_specific_monitor(owner_monitor, fn(_) { OwnerDown })
  case process.selector_receive_forever(selector) {
    Source(Finished(result, duration_ms)) -> {
      notify(result, duration_ms)
      process.kill(source)
    }
    CancelRequested | OwnerDown -> process.kill(source)
    SourceDown ->
      notify(
        Error(tool.ToolError(
          message: "tool worker exited before reporting a result",
        )),
        now() - started_at,
      )
  }
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time() -> Int

@external(erlang, "erlang", "convert_time_unit")
fn convert_time_unit(value: Int, from: TimeUnit, to: TimeUnit) -> Int

type TimeUnit {
  Native
  Millisecond
}

fn now() -> Int {
  convert_time_unit(monotonic_time(), Native, Millisecond)
}
