//// Session replay tests — JSONL → List(Message) reconstruction.
////
//// Tests verify that replay() reads a JSONL file and reconstructs
//// the conversation history accurately.

import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import pig/ai/message.{Assistant, Tool, ToolCall, User}
import pig/obs/events.{
  InferenceCompleted, InferenceStarted, ToolBlocked, ToolExecuted,
}
import pig/obs/session
import simplifile
import temporary

pub fn main() {
  gleeunit.main()
}

// ── Test Helpers ──────────────────────────────────────────────────────

fn with_temp_file(name: String, run test_fn: fn(String) -> a) -> a {
  let tmp =
    temporary.file()
    |> temporary.with_prefix("pig_replay_" <> name <> "_")
    |> temporary.with_suffix(".jsonl")
  let assert Ok(result) = temporary.create(tmp, test_fn)
  result
}

fn write_jsonl(path: String, lines: List(String)) -> Nil {
  let content = string.join(lines, "\n")
  let assert Ok(Nil) = simplifile.write(path, content <> "\n")
  Nil
}

// ── Replay Tests ──────────────────────────────────────────────────────

pub fn replay_empty_file_returns_empty_list_test() {
  use path <- with_temp_file("empty")
  let assert Ok(Nil) = simplifile.write(path, "")
  let result = session.replay(path)
  should.equal(result, Ok([]))
}

pub fn replay_file_not_found_returns_error_test() {
  let result = session.replay("/nonexistent/path/session.jsonl")
  should.be_error(result)
}

pub fn replay_single_inference_reconstructs_messages_test() {
  use path <- with_temp_file("single_inference")
  write_jsonl(path, [
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_started\",\"model\":\"gpt-4\",\"message_count\":1}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_completed\",\"duration_ms\":100,\"message\":{\"role\":\"assistant\",\"content\":\"Hello!\",\"tool_calls\":[]},\"input_messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}",
  ])
  let assert Ok(messages) = session.replay(path)
  // Should have: input_messages + assistant message = [User("Hi"), Assistant("Hello!")]
  should.equal(list.length(messages), 2)
  let assert [User(content: hi), Assistant(content: hello, ..)] = messages
  should.equal(hi, "Hi")
  should.equal(hello, "Hello!")
}

pub fn replay_with_tool_calls_reconstructs_full_history_test() {
  use path <- with_temp_file("tool_calls")
  write_jsonl(path, [
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_started\",\"model\":\"gpt-4\",\"message_count\":1}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_completed\",\"duration_ms\":50,\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c1\",\"name\":\"echo\",\"arguments\":\"{\\\"msg\\\":\\\"hello\\\"}\"}]},\"input_messages\":[{\"role\":\"user\",\"content\":\"use echo\"}]}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"tool_started\",\"tool_call\":{\"id\":\"c1\",\"name\":\"echo\",\"arguments\":\"{\\\"msg\\\":\\\"hello\\\"}\"}}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"tool_executed\",\"duration_ms\":5,\"tool_call\":{\"id\":\"c1\",\"name\":\"echo\",\"arguments\":\"{\\\"msg\\\":\\\"hello\\\"}\"},\"result\":\"{\\\"echo\\\":\\\"hello\\\"}\"}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_started\",\"model\":\"gpt-4\",\"message_count\":4}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_completed\",\"duration_ms\":80,\"message\":{\"role\":\"assistant\",\"content\":\"Done!\",\"tool_calls\":[]},\"input_messages\":[{\"role\":\"user\",\"content\":\"use echo\"},{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c1\",\"name\":\"echo\",\"arguments\":\"{\\\"msg\\\":\\\"hello\\\"}\"}]},{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"{\\\"echo\\\":\\\"hello\\\"}\"}]}",
  ])
  let assert Ok(messages) = session.replay(path)
  // Should have: input_messages from last inference + final assistant = 4 messages
  should.equal(list.length(messages), 4)
  let assert [
    User(content: use_echo),
    Assistant(content: "", tool_calls: [_tc], ..),
    Tool(tool_call_id: tc_id, content: _tool_content),
    Assistant(content: done, ..),
  ] = messages
  should.equal(use_echo, "use echo")
  should.equal(done, "Done!")
  should.equal(tc_id, "c1")
}

/// Replay handles tool_blocked events after last inference (crash recovery).
pub fn replay_with_blocked_tool_after_last_inference_test() {
  use path <- with_temp_file("blocked_tool")
  write_jsonl(path, [
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_started\",\"model\":\"gpt-4\",\"message_count\":1}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_completed\",\"duration_ms\":50,\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c1\",\"name\":\"bash\",\"arguments\":\"{}\"}]},\"input_messages\":[{\"role\":\"user\",\"content\":\"rm -rf /\"}]}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"tool_blocked\",\"tool_call\":{\"id\":\"c1\",\"name\":\"bash\",\"arguments\":\"{}\"},\"hook_name\":\"safety-guard\",\"reason\":\"dangerous command\"}",
  ])
  let assert Ok(messages) = session.replay(path)
  // Should have: input_messages from last inference + assistant + blocked tool message = 3
  should.equal(list.length(messages), 3)
  let assert [
    User(content: prompt),
    Assistant(content: "", tool_calls: [_tc], ..),
    Tool(tool_call_id: id, content: blocked_content),
  ] = messages
  should.equal(prompt, "rm -rf /")
  should.equal(id, "c1")
  // Blocked tool content should reconstruct from hook_name + reason
  should.equal(
    blocked_content,
    "Tool blocked by 'safety-guard': dangerous command",
  )
}

/// Replay handles tool_executed events after last inference (crash recovery).
/// Symmetric to replay_with_blocked_tool_after_last_inference_test but validates
/// that executed tool results are recovered from raw JSONL tool_executed events.
pub fn replay_with_executed_tool_after_last_inference_test() {
  use path <- with_temp_file("executed_tool")
  write_jsonl(path, [
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_started\",\"model\":\"gpt-4\",\"message_count\":1}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_completed\",\"duration_ms\":50,\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c1\",\"name\":\"ping\",\"arguments\":\"{}\"}]},\"input_messages\":[{\"role\":\"user\",\"content\":\"ping me\"}]}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"tool_executed\",\"duration_ms\":5,\"tool_call\":{\"id\":\"c1\",\"name\":\"ping\",\"arguments\":\"{}\"},\"result\":\"pong\"}",
  ])
  let assert Ok(messages) = session.replay(path)
  // Should have: input_messages from last inference + assistant + executed tool message = 3
  should.equal(list.length(messages), 3)
  let assert [
    User(content: prompt),
    Assistant(content: "", tool_calls: [_tc], ..),
    Tool(tool_call_id: id, content: tool_content),
  ] = messages
  should.equal(prompt, "ping me")
  should.equal(id, "c1")
  // Executed tool content should come from the tool_executed result field
  should.equal(tool_content, "pong")
}

// ── Round-trip Tests: format_event → write → replay ────────────────

/// Verify that format_event produces JSONL that replay() can parse back
/// into the original messages. This is the critical session recovery path.
pub fn round_trip_single_inference_test() {
  use path <- with_temp_file("round_trip_single")
  let input_messages = [User("Hello")]
  let assistant_msg = Assistant("Hi there!", [], None)
  let line1 =
    InferenceStarted(model: "gpt-4", message_count: 1)
    |> session.format_event
  let line2 =
    InferenceCompleted(
      message: assistant_msg,
      response_id: None,
      response_model: None,
      finish_reason: None,
      input_tokens: None,
      output_tokens: None,
      duration_ms: 100,
      input_messages: input_messages,
    )
    |> session.format_event
  write_jsonl(path, [line1, line2])
  let assert Ok(messages) = session.replay(path)
  // input_messages + assistant response = 2 messages
  should.equal(list.length(messages), 2)
  let assert [User(content: hi), Assistant(content: resp, ..)] = messages
  should.equal(hi, "Hello")
  should.equal(resp, "Hi there!")
}

/// Verify round-trip with tool calls — the full agent loop cycle.
/// input_messages should be st.history (no system prompt), and replay
/// should recover exactly those messages.
pub fn round_trip_full_tool_loop_test() {
  use path <- with_temp_file("round_trip_tools")
  let history = [
    User("Use echo"),
    Assistant(
      "",
      [ToolCall(id: "c1", name: "echo", arguments_json: "{\"msg\":\"hi\"}")],
      None,
    ),
    Tool(tool_call_id: "c1", content: "{\"echo\":\"hi\"}"),
  ]
  let final_response = Assistant("Done!", [], None)
  let line1 =
    InferenceStarted(model: "gpt-4", message_count: 4)
    |> session.format_event
  let line2 =
    InferenceCompleted(
      message: final_response,
      response_id: None,
      response_model: None,
      finish_reason: None,
      input_tokens: None,
      output_tokens: None,
      duration_ms: 80,
      input_messages: history,
    )
    |> session.format_event
  write_jsonl(path, [line1, line2])
  let assert Ok(messages) = session.replay(path)
  // 3 history messages + 1 final assistant = 4
  should.equal(list.length(messages), 4)
  let assert [
    User(content: use_echo),
    Assistant(content: "", tool_calls: [tc], ..),
    Tool(tool_call_id: tc_id, content: _),
    Assistant(content: done, ..),
  ] = messages
  should.equal(use_echo, "Use echo")
  should.equal(tc.id, "c1")
  should.equal(tc_id, "c1")
  should.equal(done, "Done!")
}

/// Verify that history stored without system prompt round-trips correctly.
/// After replay, messages_for_provider should prepend the system prompt.
pub fn round_trip_no_system_prompt_in_history_test() {
  use path <- with_temp_file("round_trip_no_sys")
  // History is just user/assistant — no system prompt
  let history = [User("What is 2+2?")]
  let response = Assistant("4", [], None)
  let line =
    InferenceCompleted(
      message: response,
      response_id: None,
      response_model: None,
      finish_reason: None,
      input_tokens: None,
      output_tokens: None,
      duration_ms: 50,
      input_messages: history,
    )
    |> session.format_event
  write_jsonl(path, [line])
  let assert Ok(messages) = session.replay(path)
  // Should recover exactly the history + response, no system prompt
  should.equal(list.length(messages), 2)
  let assert [User(content: q), Assistant(content: a, ..)] = messages
  should.equal(q, "What is 2+2?")
  should.equal(a, "4")
}

// ── Hook Round-trip Tests ──────────────────────────────────────────

/// Verify that a ToolBlocked event (hook blocks a tool) round-trips
/// through format_event → replay. The replay should reconstruct the
/// Tool message with the blocked-content format.
pub fn round_trip_blocked_tool_test() {
  use path <- with_temp_file("round_trip_blocked")
  let call = ToolCall(id: "c1", name: "bash", arguments_json: "{}")
  let history = [User("rm -rf /")]
  let assistant_with_calls = Assistant("", [call], None)
  // InferenceCompleted records history (original, no system prompt)
  // Then tool is blocked
  let inference_line =
    InferenceCompleted(
      message: assistant_with_calls,
      response_id: None,
      response_model: None,
      finish_reason: None,
      input_tokens: None,
      output_tokens: None,
      duration_ms: 50,
      input_messages: history,
    )
    |> session.format_event
  let blocked_line =
    ToolBlocked(tool_call: call, hook_name: "safety", reason: "dangerous")
    |> session.format_event
  write_jsonl(path, [inference_line, blocked_line])
  let assert Ok(messages) = session.replay(path)
  // input_messages + assistant + blocked tool = 3
  should.equal(list.length(messages), 3)
  let assert [
    User(content: prompt),
    Assistant(content: "", tool_calls: [tc], ..),
    Tool(tool_call_id: id, content: blocked_content),
  ] = messages
  should.equal(prompt, "rm -rf /")
  should.equal(tc.id, "c1")
  should.equal(id, "c1")
  should.equal(blocked_content, "Tool blocked by 'safety': dangerous")
}

/// Verify that a ToolExecuted event with hook-transformed result
/// round-trips correctly. After hooks transform the result, the
/// ToolExecuted event carries the transformed content.
pub fn round_trip_transformed_result_test() {
  use path <- with_temp_file("round_trip_transformed")
  let call =
    ToolCall(id: "c2", name: "search", arguments_json: "{\"q\":\"test\"}")
  let history = [
    User("search for test"),
    Assistant("", [call], None),
  ]
  let final_response = Assistant("Here are the results", [], None)
  // First inference: user asks, assistant calls tool
  let inference1 =
    InferenceCompleted(
      message: Assistant("", [call], None),
      response_id: None,
      response_model: None,
      finish_reason: None,
      input_tokens: None,
      output_tokens: None,
      duration_ms: 50,
      input_messages: [User("search for test")],
    )
    |> session.format_event
  // ToolExecuted with transformed (redacted) content — post-hook result
  let tool_line =
    ToolExecuted(
      tool_call: call,
      result: "[REDACTED by privacy-hook]",
      duration_ms: 10,
    )
    |> session.format_event
  // Second inference with tool result in history
  let inference2 =
    InferenceCompleted(
      message: final_response,
      response_id: None,
      response_model: None,
      finish_reason: None,
      input_tokens: None,
      output_tokens: None,
      duration_ms: 80,
      input_messages: history,
    )
    |> session.format_event
  write_jsonl(path, [inference1, tool_line, inference2])
  let assert Ok(messages) = session.replay(path)
  // Last InferenceCompleted has 2 input_messages + 1 final assistant = 3
  // (the ToolExecuted is before the last inference, so not picked up as partial)
  should.equal(list.length(messages), 3)
  let assert [
    User(content: q),
    Assistant(content: "", tool_calls: [tc], ..),
    Assistant(content: resp, ..),
  ] = messages
  should.equal(q, "search for test")
  should.equal(tc.id, "c2")
  should.equal(resp, "Here are the results")
}

/// Verify that a partial session (crash after tool execution, before
/// next inference) recovers Tool messages from ToolExecuted events.
/// This tests the "partial session" path in replay_lines.
pub fn round_trip_partial_session_with_transformed_tool_test() {
  use path <- with_temp_file("round_trip_partial")
  let call =
    ToolCall(
      id: "c3",
      name: "read",
      arguments_json: "{\"path\":\"/etc/passwd\"}",
    )
  // Only one inference completed, then a tool executed — no final inference
  let inference_line =
    InferenceCompleted(
      message: Assistant("", [call], None),
      response_id: None,
      response_model: None,
      finish_reason: None,
      input_tokens: None,
      output_tokens: None,
      duration_ms: 50,
      input_messages: [User("read passwd")],
    )
    |> session.format_event
  // ToolExecuted with transformed result (hook rewrote it)
  let tool_line =
    ToolExecuted(
      tool_call: call,
      result: "[BLOCKED by security-hook]",
      duration_ms: 5,
    )
    |> session.format_event
  write_jsonl(path, [inference_line, tool_line])
  let assert Ok(messages) = session.replay(path)
  // input_messages + assistant + tool (from partial recovery) = 3
  should.equal(list.length(messages), 3)
  let assert [
    User(content: prompt),
    Assistant(content: "", tool_calls: [tc], ..),
    Tool(tool_call_id: id, content: tool_content),
  ] = messages
  should.equal(prompt, "read passwd")
  should.equal(tc.id, "c3")
  should.equal(id, "c3")
  // The transformed result from ToolExecuted should be preserved
  should.equal(tool_content, "[BLOCKED by security-hook]")
}
