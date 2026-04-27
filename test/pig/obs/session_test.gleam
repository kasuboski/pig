import gleeunit
import gleeunit/should
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some, None}
import gleam/string
import gleam/erlang/process
import pig/ai/error.{ApiError}
import pig/ai/message.{User, Assistant, ToolCall}
import pig/obs/events.{
  SessionStarted, InferenceCompleted, ToolExecuted, InferenceFailed,
  SessionEnded, NormalEnd, MaxIterationsExceeded,
}
import pig/obs/session
import simplifile

pub fn main() {
  gleeunit.main()
}

// ── Pure serialization tests (test format_event) ─────────────────────

pub fn format_session_started_produces_valid_json_test() {
  let event =
    SessionStarted(
      agent_id: Some("agent-123"),
      agent_name: Some("Math Tutor"),
      model: "gpt-4",
      provider_name: Some("openai"),
      system_prompt: Some("You are helpful"),
    )

  let json_str = session.format_event(event)

  // Verify it's valid JSON
  let assert Ok(_parsed) = json.parse(from: json_str, using: decode.dynamic)

  // Verify it contains the event type
  json_str
  |> string.contains("session_started")
  |> should.be_true
}

pub fn format_session_started_single_line_test() {
  let event =
    SessionStarted(
      agent_id: Some("agent-123"),
      agent_name: Some("Math Tutor"),
      model: "gpt-4",
      provider_name: Some("openai"),
      system_prompt: Some("You are helpful"),
    )

  let json_str = session.format_event(event)

  // Verify no newlines in the JSON string
  string.contains(json_str, "\n")
  |> should.be_false
}

pub fn format_inference_completed_includes_fields_test() {
  let message = Assistant(content: "hi", tool_calls: [], thinking: None)
  let event =
    InferenceCompleted(
      message: message,
      response_id: Some("chatcmpl-123"),
      response_model: Some("gpt-4"),
      finish_reason: Some("stop"),
      input_tokens: Some(10),
      output_tokens: Some(5),
      duration_ms: 150,
      input_messages: [User("hello")],
    )

  let json_str = session.format_event(event)

  // Verify all expected values are in the JSON
  json_str
  |> string.contains("inference_completed")
  |> should.be_true

  json_str
  |> string.contains("chatcmpl-123")
  |> should.be_true

  json_str
  |> string.contains("stop")
  |> should.be_true

  json_str
  |> string.contains("150")
  |> should.be_true
}

pub fn format_tool_executed_includes_fields_test() {
  let tool_call = ToolCall(id: "c1", name: "calculator", arguments_json: "{\"expr\":\"2+2\"}")
  let event =
    ToolExecuted(
      tool_call: tool_call,
      result: "4",
      duration_ms: 3,
    )

  let json_str = session.format_event(event)

  // Verify all expected values are in the JSON
  json_str
  |> string.contains("tool_executed")
  |> should.be_true

  json_str
  |> string.contains("calculator")
  |> should.be_true

  json_str
  |> string.contains("2+2")
  |> should.be_true

  json_str
  |> string.contains("4")
  |> should.be_true

  json_str
  |> string.contains("3")
  |> should.be_true
}

pub fn format_inference_failed_includes_error_test() {
  let event =
    InferenceFailed(
      error: ApiError("rate limited"),
      duration_ms: 0,
      input_messages: [],
    )

  let json_str = session.format_event(event)

  // Verify error info is in the JSON
  json_str
  |> string.contains("inference_failed")
  |> should.be_true

  json_str
  |> string.contains("rate limited")
  |> should.be_true
}

pub fn format_session_ended_normal_test() {
  let event = SessionEnded(NormalEnd)

  let json_str = session.format_event(event)

  // Verify session ended and normal_end are present
  json_str
  |> string.contains("session_ended")
  |> should.be_true

  json_str
  |> string.contains("normal_end")
  |> should.be_true
}

pub fn format_session_ended_max_iterations_test() {
  let event = SessionEnded(MaxIterationsExceeded(10))

  let json_str = session.format_event(event)

  // Verify max iterations info is present
  json_str
  |> string.contains("session_ended")
  |> should.be_true

  json_str
  |> string.contains("max_iterations_exceeded")
  |> should.be_true

  json_str
  |> string.contains("10")
  |> should.be_true
}

// ── Actor integration tests ───────────────────────────────────────────

pub fn start_returns_ok_test() {
  // Create test_tmp directory if it doesn't exist
  let _ = simplifile.create_directory_all("./test_tmp")

  let test_file = "./test_tmp/session_test_1.jsonl"

  // Clean up any existing file
  let _ = simplifile.delete(test_file)

  let assert Ok(_writer) = session.start(test_file)

  // Clean up
  let _ = simplifile.delete(test_file)
}

pub fn write_single_event_test() {
  // Create test_tmp directory if it doesn't exist
  let _ = simplifile.create_directory_all("./test_tmp")

  let test_file = "./test_tmp/session_test_2.jsonl"

  // Clean up any existing file
  let _ = simplifile.delete(test_file)

  let assert Ok(writer) = session.start(test_file)

  let event =
    SessionStarted(
      agent_id: Some("agent-123"),
      agent_name: Some("Math Tutor"),
      model: "gpt-4",
      provider_name: Some("openai"),
      system_prompt: Some("You are helpful"),
    )

  session.record(writer, event)

  // Wait for async write
  process.sleep(100)

  // Read file and verify
  let assert Ok(contents) = simplifile.read(test_file)

  let lines = string.split(contents, "\n") |> list.filter(fn(l) { l != "" })

  lines
  |> list.length
  |> should.equal(1)

  // Verify it's valid JSON
  let first_line = list.first(lines) |> should.be_ok

  let assert Ok(_parsed) = json.parse(from: first_line, using: decode.dynamic)

  // Clean up
  session.stop(writer)
  process.sleep(50)
  let _ = simplifile.delete(test_file)
}

pub fn write_multiple_events_in_order_test() {
  // Create test_tmp directory if it doesn't exist
  let _ = simplifile.create_directory_all("./test_tmp")

  let test_file = "./test_tmp/session_test_3.jsonl"

  // Clean up any existing file
  let _ = simplifile.delete(test_file)

  let assert Ok(writer) = session.start(test_file)

  let event1 =
    SessionStarted(
      agent_id: Some("agent-123"),
      agent_name: Some("Math Tutor"),
      model: "gpt-4",
      provider_name: Some("openai"),
      system_prompt: Some("You are helpful"),
    )

  let event2 =
    InferenceCompleted(
      message: Assistant(content: "hi", tool_calls: [], thinking: None),
      response_id: Some("chatcmpl-123"),
      response_model: Some("gpt-4"),
      finish_reason: Some("stop"),
      input_tokens: Some(10),
      output_tokens: Some(5),
      duration_ms: 150,
      input_messages: [User("hello")],
    )

  let event3 = SessionEnded(NormalEnd)

  session.record(writer, event1)
  session.record(writer, event2)
  session.record(writer, event3)

  // Wait for async writes
  process.sleep(100)

  // Read file and verify
  let assert Ok(contents) = simplifile.read(test_file)

  let lines = string.split(contents, "\n") |> list.filter(fn(l) { l != "" })

  lines
  |> list.length
  |> should.equal(3)

  // Verify order by checking each line contains the expected event type
  let first_line = list.first(lines) |> should.be_ok
  first_line
  |> string.contains("session_started")
  |> should.be_true

  let second_line = list.drop(lines, 1) |> list.first |> should.be_ok
  second_line
  |> string.contains("inference_completed")
  |> should.be_true

  let third_line = list.drop(lines, 2) |> list.first |> should.be_ok
  third_line
  |> string.contains("session_ended")
  |> should.be_true

  // Clean up
  session.stop(writer)
  process.sleep(50)
  let _ = simplifile.delete(test_file)
}

pub fn stop_terminates_actor_test() {
  // Create test_tmp directory if it doesn't exist
  let _ = simplifile.create_directory_all("./test_tmp")

  let test_file = "./test_tmp/session_test_4.jsonl"

  // Clean up any existing file
  let _ = simplifile.delete(test_file)

  let assert Ok(writer) = session.start(test_file)

  session.stop(writer)

  // Wait for actor to terminate
  process.sleep(100)

  // Verify process is down by trying to send a message
  // This should not crash the test - the actor should be dead
  let event =
    SessionStarted(
      agent_id: Some("agent-123"),
      agent_name: Some("Math Tutor"),
      model: "gpt-4",
      provider_name: Some("openai"),
      system_prompt: Some("You are helpful"),
    )

  // This should not cause issues if the actor is properly stopped
  session.record(writer, event)
  process.sleep(50)

  // Clean up
  let _ = simplifile.delete(test_file)
}
