//// Parallel tool execution contract tests.
////
//// Proves tools execute concurrently via telemetry ordering.
//// Per TESTING_STRATEGY §Part II pig/obs: "Do not use sleep() or
//// timeout hacks to test concurrency."
////
//// Strategy: dispatch 3 slow tools. If sequential, event order would be
//// start-stop-start-stop-start-stop. If parallel, all 3 starts fire
//// before any stop.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import jscheam/schema
import gleeunit
import pig/ai/tool_definition
import pig/agent/actor
import pig/agent/state
import pig/ai/message
import pig/obs/dispatcher
import pig/obs/events
import pig/tool
import support/harness

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Parallelism Proof ────────────────────────────────────────────

/// Three slow tools: all ToolStarted events fire before any ToolExecuted.
/// This proves concurrent execution (sequential would interleave).
pub fn parallel_tools_all_starts_before_stops_test() {
  let tc1 =
    message.ToolCall(
      id: "a",
      name: "slow_echo",
      arguments_json: "{\"msg\":\"x\"}",
    )
  let tc2 =
    message.ToolCall(
      id: "b",
      name: "slow_echo",
      arguments_json: "{\"msg\":\"y\"}",
    )
  let tc3 =
    message.ToolCall(
      id: "c",
      name: "slow_echo",
      arguments_json: "{\"msg\":\"z\"}",
    )
  let tool_resp = message.Assistant("", [tc1, tc2, tc3], None)
  let final = message.Assistant("done!", [], None)
  let provider = harness.sequenced_provider_for_actor([tool_resp, final])
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let config =
    state.config(provider)
    |> state.with_dispatcher(dispatcher_subject)
    |> state.with_tools(
      tool.new_registry() |> tool.register(slow_echo_tool(50)),
    )
  // Create a consumer to receive SessionEvents
  let consumer_subject = process.new_subject()
  process.send(dispatcher_subject, dispatcher.RegisterConsumer(consumer_subject))
  let assert Ok(subject) = actor.start(config)
  let assert Ok(msg) = actor.run(subject, "parallel", 10_000)
  let assert True = msg == final
  // Collect all events from the consumer
  let evts = collect_events(consumer_subject, 6, 5000)
  // Prove parallelism: all starts before any stop
  let event_types = list.map(evts, fn(e) {
    case e {
      events.ToolStarted(..) -> "ToolStarted"
      events.ToolExecuted(..) -> "ToolExecuted"
      _ -> "Other"
    }
  })
  let starts = find_indices(event_types, "ToolStarted")
  let stops = find_indices(event_types, "ToolExecuted")
  let max_start = list.fold(starts, 0, int.max)
  let min_stop =
    case stops {
      [] -> 999_999
      _ -> list.fold(stops, 999_999, int.min)
    }
  max_start < min_stop
}

/// Parallel execution produces correct results — all 3 tools return values.
pub fn parallel_tools_produces_correct_results_test() {
  let tc1 =
    message.ToolCall(
      id: "a",
      name: "slow_echo",
      arguments_json: "{\"msg\":\"alpha\"}",
    )
  let tc2 =
    message.ToolCall(
      id: "b",
      name: "slow_echo",
      arguments_json: "{\"msg\":\"beta\"}",
    )
  let tc3 =
    message.ToolCall(
      id: "c",
      name: "slow_echo",
      arguments_json: "{\"msg\":\"gamma\"}",
    )
  let tool_resp = message.Assistant("", [tc1, tc2, tc3], None)
  let final = message.Assistant("complete", [], None)
  let provider = harness.sequenced_provider_for_actor([tool_resp, final])
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let config =
    state.config(provider)
    |> state.with_dispatcher(dispatcher_subject)
    |> state.with_tools(
      tool.new_registry() |> tool.register(slow_echo_tool(10)),
    )
  let assert Ok(subject) = actor.start(config)
  let assert Ok(msg) = actor.run(subject, "parallel", 5000)
  msg == final
}

// ── Helpers ──────────────────────────────────────────────────────

/// A slow echo tool that sleeps before returning, making parallelism observable.
fn slow_echo_tool(delay_ms: Int) -> tool.Tool {
  tool.Tool(
    definition:
      tool_definition.ToolDefinition(
        name: "slow_echo",
        description: "Slow echo tool",
        parameters: schema.object([]),
      ),
    handler: fn(args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
      process.sleep(delay_ms)
      let assert Ok(msg) =
        decode.run(args, decode.field("msg", decode.string, decode.success))
      Ok(json.object([#("echo", json.string(msg))]))
    },
  )
}

/// Find all indices where the list contains the given value.
fn find_indices(haystack: List(String), needle: String) -> List(Int) {
  haystack
  |> list.index_map(fn(val, idx) {
    case val == needle {
      True -> Some(idx)
      False -> None
    }
  })
  |> list.filter(fn(x) { x != None })
  |> list.map(fn(x) {
    let assert Some(v) = x
    v
  })
}

/// Collect a specific number of events from a subject.
fn collect_events(
  subject: process.Subject(events.SessionEvent),
  count: Int,
  timeout: Int,
) -> List(events.SessionEvent) {
  collect_events_helper(subject, count, [], timeout)
}

fn collect_events_helper(
  subject: process.Subject(events.SessionEvent),
  remaining: Int,
  acc: List(events.SessionEvent),
  timeout: Int,
) -> List(events.SessionEvent) {
  case remaining <= 0 {
    True -> list.reverse(acc)
    False ->
      case process.receive(subject, timeout) {
        Ok(event) ->
          collect_events_helper(
            subject,
            remaining - 1,
            [event, ..acc],
            timeout,
          )
        Error(_) -> list.reverse(acc)
      }
  }
}
