//// Agent core loop contract tests.
////
//// Scenario-driven tests verifying state transitions, tool dispatch,
//// loop termination, and error resilience. Per TESTING_STRATEGY §Part II:
//// "Verify state transitions, tool dispatching, and loop termination."

import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import pig/agent/core
import pig/agent/state
import pig/ai/error
import pig/ai/message
import support/harness

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Step Contract ────────────────────────────────────────────────

/// Provider returns text → step yields Complete with that message.
pub fn step_text_response_completes_test() {
  let resp = message.Assistant("hello!", [], None)
  let s =
    harness.state_for_step([resp], [])
    |> state.add_message(message.User("hi"))
  let assert core.Complete(msg) = core.step(s)
  msg == resp
}

/// Provider returns tool calls → step yields NeedsToolExecution.
pub fn step_tool_call_defers_execution_test() {
  let tc =
    message.ToolCall(id: "c1", name: "echo", arguments_json: "{}")
  let resp = message.Assistant("", [tc], None)
  let s =
    harness.state_for_step([resp], [harness.echo_tool()])
    |> state.add_message(message.User("run echo"))
  let assert core.NeedsToolExecution(calls, _) = core.step(s)
  calls == [tc]
}

/// Provider returns tool calls → assistant message is in history before tools execute.
pub fn step_tool_call_records_assistant_in_history_test() {
  let tc =
    message.ToolCall(id: "c1", name: "echo", arguments_json: "{}")
  let resp = message.Assistant("", [tc], None)
  let s =
    harness.state_for_step([resp], [harness.echo_tool()])
    |> state.add_message(message.User("hi"))
  let assert core.NeedsToolExecution(_, updated) = core.step(s)
  let assert Ok(message.Assistant("", [_], None)) =
    state.history(updated) |> list.last
  True
}

/// Provider fails → step yields StepError.
pub fn step_provider_error_yields_step_error_test() {
  let s =
    harness.state_for_step([], [])
    |> state.config_put_provider(harness.failing_provider)
    |> state.add_message(message.User("hi"))
  let assert core.StepError(e) = core.step(s)
  e == error.ApiError("provider failed")
}

/// System prompt is passed to the provider as the first message.
pub fn step_system_prompt_reaches_provider_test() {
  let resp = message.Assistant("ok", [], None)
  let verifying_provider = fn(msgs, _tools) {
    case list.first(msgs) {
      Ok(message.System("sys prompt",)) -> Ok(resp)
      _ -> Error(error.ApiError("missing system prompt"))
    }
  }
  let s =
    harness.state_with_system_prompt([], [], "sys prompt")
    |> state.config_put_provider(verifying_provider)
    |> state.add_message(message.User("hi"))
  let assert core.Complete(msg) = core.step(s)
  msg == resp
}

// ── Execute Tools Contract ───────────────────────────────────────

/// Successful tool execution appends Tool message with result.
pub fn execute_tools_appends_result_message_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"hi\"}",
    )
  let s =
    harness.state_for_step([], [harness.echo_tool()])
    |> state.add_message(message.Assistant("", [tc], None))
  let advanced = core.execute_tools_and_advance(s, [tc])
  let assert Ok(message.Tool(tool_call_id: "c1", content:)) =
    state.history(advanced) |> list.last
  content == "{\"echo\":\"hi\"}"
}

/// Failed tool execution appends Tool message with error content.
pub fn execute_tools_error_appends_error_message_test() {
  let tc =
    message.ToolCall(id: "c1", name: "boom", arguments_json: "{}")
  let s =
    harness.state_for_step([], [harness.failing_tool()])
    |> state.add_message(message.Assistant("", [tc], None))
  let advanced = core.execute_tools_and_advance(s, [tc])
  let assert Ok(message.Tool(tool_call_id: "c1", content:)) =
    state.history(advanced) |> list.last
  content == "Tool error: tool exploded"
}

/// Unknown tool appends Tool message with error — no crash.
pub fn execute_tools_unknown_tool_no_crash_test() {
  let tc =
    message.ToolCall(id: "c1", name: "nonexistent", arguments_json: "{}")
  let s =
    harness.state_for_step([], [])
    |> state.add_message(message.Assistant("", [tc], None))
  let advanced = core.execute_tools_and_advance(s, [tc])
  let assert Ok(message.Tool(tool_call_id: "c1", content:)) =
    state.history(advanced) |> list.last
  string.starts_with(content, "Tool error:")
}

/// Multiple tool calls produce one Tool message each.
pub fn execute_tools_multiple_produces_n_messages_test() {
  let tc1 =
    message.ToolCall(id: "a", name: "echo", arguments_json: "{\"msg\":\"x\"}")
  let tc2 =
    message.ToolCall(id: "b", name: "echo", arguments_json: "{\"msg\":\"y\"}")
  let s =
    harness.state_for_step([], [harness.echo_tool()])
    |> state.add_message(message.Assistant("", [tc1, tc2], None))
  let advanced = core.execute_tools_and_advance(s, [tc1, tc2])
  // Assistant + 2 Tool messages = 3
  list.length(state.history(advanced)) == 3
}

// ── Run To Completion: Scenario Tests ────────────────────────────

/// Scenario 1: Provider returns text immediately.
pub fn scenario_simple_response_test() {
  let final = message.Assistant("4", [], None)
  let assert Ok(msg) = harness.check_scenario(
    "What is 2+2?",
    [final],
    [],
  )
  msg == final
}

/// Scenario 2: Provider calls one tool, then returns text.
pub fn scenario_single_tool_call_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"test\"}",
    )
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("done!", [], None)
  let assert Ok(msg) = harness.check_scenario(
    "use echo",
    [tool_resp, final],
    [harness.echo_tool()],
  )
  msg == final
}

/// Scenario 3: Provider calls 3 tools at once, then returns text.
pub fn scenario_multi_tool_call_test() {
  let tc1 =
    message.ToolCall(id: "a", name: "echo", arguments_json: "{\"msg\":\"x\"}")
  let tc2 =
    message.ToolCall(id: "b", name: "echo", arguments_json: "{\"msg\":\"y\"}")
  let tc3 =
    message.ToolCall(id: "c", name: "echo", arguments_json: "{\"msg\":\"z\"}")
  let tool_resp = message.Assistant("", [tc1, tc2, tc3], None)
  let final = message.Assistant("all done!", [], None)
  let assert Ok(msg) = harness.check_scenario(
    "multi call",
    [tool_resp, final],
    [harness.echo_tool()],
  )
  msg == final
}

/// Scenario 4: Chained — tool call → response → tool call → response → text.
pub fn scenario_chained_tool_calls_test() {
  let tc1 =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"first\"}",
    )
  let tc2 =
    message.ToolCall(
      id: "c2",
      name: "echo",
      arguments_json: "{\"msg\":\"second\"}",
    )
  let resp1 = message.Assistant("", [tc1], None)
  let resp2 = message.Assistant("", [tc2], None)
  let final = message.Assistant("chained complete!", [], None)
  let assert Ok(msg) = harness.check_scenario(
    "chain",
    [resp1, resp2, final],
    [harness.echo_tool()],
  )
  msg == final
}

/// Provider error terminates the loop with Error.
pub fn scenario_provider_error_test() {
  let s =
    harness.state_for_step([], [])
    |> state.config_put_provider(harness.failing_provider)
    |> state.add_message(message.User("hello"))
  let assert Error(e) = core.run_to_completion(s)
  e == error.ApiError("provider failed")
}

/// Circuit breaker: infinite tool-call loop terminates at max_iterations.
pub fn scenario_max_iterations_circuit_breaker_test() {
  let tc =
    message.ToolCall(
      id: "loop",
      name: "echo",
      arguments_json: "{\"msg\":\"x\"}",
    )
  let looping = message.Assistant("", [tc], None)
  let s =
    harness.state_with_max_iterations(
      [looping],
      [harness.echo_tool()],
      2,
    )
    |> state.add_message(message.User("loop"))
  let assert Error(error.ApiError(message:)) = core.run_to_completion(s)
  string.contains(message, "exceeded maximum iterations")
}

/// Tool error does NOT kill the loop — LLM sees error and adapts.
pub fn scenario_tool_error_recovery_test() {
  let tc =
    message.ToolCall(id: "c1", name: "boom", arguments_json: "{}")
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("recovered!", [], None)
  let assert Ok(msg) = harness.check_scenario(
    "try boom",
    [tool_resp, final],
    [harness.failing_tool()],
  )
  msg == final
}
