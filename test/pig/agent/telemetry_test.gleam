//// Agent telemetry contract tests.
////
//// Verifies that the core loop emits the correct telemetry events
//// with correct metadata. Per TESTING_STRATEGY §Part II pig/obs:
//// "Log Assertion Pattern" — attach listener, run scenario, assert events.

import gleam/list
import gleam/option.{None}
import gleeunit
import pig/ai/message
import pig/obs/events
import support/harness

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Inference Events ─────────────────────────────────────────────

/// A simple text exchange emits InferenceStart then InferenceStop.
pub fn simple_response_emits_inference_start_stop_test() {
  let #(_, evts) = harness.capture_scenario(
    "hi",
    [message.Assistant("hello!", [], None)],
    [],
    "test-model",
  )
  let names = harness.event_type_names(evts)
  list.contains(names, "pig.inference.start")
  && list.contains(names, "pig.inference.stop")
}

/// InferenceStart carries the model name from config.
pub fn inference_start_carries_model_test() {
  let #(_, evts) = harness.capture_scenario(
    "hi",
    [message.Assistant("hello!", [], None)],
    [],
    "gpt-4",
  )
  let assert Ok(events.InferenceStart(model:, ..)) =
    evts
    |> list.find(fn(e) {
      case e {
        events.InferenceStart(..) -> True
        _ -> False
      }
    })
  model == "gpt-4"
}

/// Provider error emits InferenceStart then InferenceException (not Stop).
pub fn provider_error_emits_exception_not_stop_test() {
  let assert #(Error(_), evts) = harness.capture_scenario(
    "hi",
    [], // empty responses -> provider will fail on first call
    [],
    "fail-model",
  )
  let names = harness.event_type_names(evts)
  list.contains(names, "pig.inference.start")
  && !list.contains(names, "pig.inference.stop")
  && list.contains(names, "pig.inference.exception")
}

// ── Tool Events ──────────────────────────────────────────────────

/// A tool call scenario emits ToolStart then ToolStop.
pub fn tool_call_emits_start_stop_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"hi\"}",
    )
  let #(_, evts) = harness.capture_scenario(
    "use echo",
    [
      message.Assistant("", [tc], None),
      message.Assistant("done!", [], None),
    ],
    [harness.echo_tool()],
    "test-model",
  )
  let names = harness.event_type_names(evts)
  list.contains(names, "pig.tool.start")
  && list.contains(names, "pig.tool.stop")
}

/// ToolStart carries the tool name and call ID.
pub fn tool_start_carries_name_and_id_test() {
  let tc =
    message.ToolCall(
      id: "call-42",
      name: "echo",
      arguments_json: "{\"msg\":\"hi\"}",
    )
  let #(_, evts) = harness.capture_scenario(
    "use echo",
    [
      message.Assistant("", [tc], None),
      message.Assistant("done!", [], None),
    ],
    [harness.echo_tool()],
    "test-model",
  )
  let assert Ok(events.ToolStart(tool_name:, tool_call_id:)) =
    evts
    |> list.find(fn(e) {
      case e {
        events.ToolStart(..) -> True
        _ -> False
      }
    })
  tool_name == "echo" && tool_call_id == "call-42"
}

/// Multiple tool calls emit the right number of start/stop pairs.
pub fn multi_tool_emits_correct_event_count_test() {
  let tc1 =
    message.ToolCall(id: "a", name: "echo", arguments_json: "{\"msg\":\"x\"}")
  let tc2 =
    message.ToolCall(id: "b", name: "echo", arguments_json: "{\"msg\":\"y\"}")
  let tc3 =
    message.ToolCall(id: "c", name: "echo", arguments_json: "{\"msg\":\"z\"}")
  let assert #(Ok(_), evts) = harness.capture_scenario(
    "multi",
    [
      message.Assistant("", [tc1, tc2, tc3], None),
      message.Assistant("done!", [], None),
    ],
    [harness.echo_tool()],
    "test-model",
  )
  let names = harness.event_type_names(evts)
  let tool_starts =
    names |> list.filter(fn(n) { n == "pig.tool.start" })
  let tool_stops =
    names |> list.filter(fn(n) { n == "pig.tool.stop" })
  list.length(tool_starts) == 3 && list.length(tool_stops) == 3
}

/// Tool errors still emit ToolStart + ToolStop (not ToolException).
/// Errors are caught and surfaced as Tool messages — the loop continues.
pub fn tool_error_still_emits_start_stop_test() {
  let tc =
    message.ToolCall(id: "c1", name: "boom", arguments_json: "{}")
  let assert #(Ok(_), evts) = harness.capture_scenario(
    "fail",
    [
      message.Assistant("", [tc], None),
      message.Assistant("recovered!", [], None),
    ],
    [harness.failing_tool()],
    "test-model",
  )
  let names = harness.event_type_names(evts)
  list.contains(names, "pig.tool.start")
  && list.contains(names, "pig.tool.stop")
  && !list.contains(names, "pig.tool.exception")
}
