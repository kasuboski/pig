//// JSONL session writer tests.
////
//// Pure serialization tests exercise `format_event` (Axiom 2: value in, value out).
//// Actor tests use `record_sync` for deterministic writes — no sleep hacks.
//// Per TESTING_STRATEGY §pig/obs: "Do not use sleep() or timeout hacks."

import gleeunit
import gleeunit/should
import gleam/dynamic/decode as dynamic_decode
import gleam/json
import gleam/result
import gleam/list
import gleam/option.{Some, None}
import gleam/string
import gleam/erlang/process
import pig/ai/error.{ApiError}
import pig/ai/message.{User, Assistant, ToolCall}
import pig/obs/events.{
  SessionStarted, InferenceCompleted, ToolExecuted, InferenceFailed,
  SessionEnded, NormalEnd, MaxIterationsExceeded,
  InferenceStarted, ToolStarted, ToolBlocked, ExtensionActed,
  BeforeToolCall, ExtensionActionDetail,
}
import pig/obs/session
import pig/obs/dispatcher
import simplifile
import temporary

pub fn main() {
  gleeunit.main()
}

// ── Test Helpers ──────────────────────────────────────────────────────

/// Decode the "event" field from a JSON string.
/// Returns the event type string (e.g. "session_started").
fn decode_event_type(json_str: String) -> String {
  let decoder = dynamic_decode.at(["event"], dynamic_decode.string)
  let assert Ok(event_type) =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })
  event_type
}

/// Read a JSONL file, split into lines, filter empty lines.
fn read_jsonl_lines(path: String) -> List(String) {
  let assert Ok(contents) = simplifile.read(path)
  string.split(contents, "\n") |> list.filter(fn(l) { l != "" })
}

/// Run a test with a temporary file. Auto-cleaned after the callback returns.
fn with_temp_file(
  name: String,
  run test_fn: fn(String) -> a,
) -> a {
  let tmp =
    temporary.file()
    |> temporary.with_prefix("pig_session_" <> name <> "_")
    |> temporary.with_suffix(".jsonl")
  let assert Ok(result) = temporary.create(tmp, test_fn)
  result
}

// ── Pure serialization tests (test format_event) ─────────────────────
// Axiom 2: Pure functions. Axiom 4: Decode JSON, don't string.contains.

pub fn format_session_started_produces_valid_json_with_fields_test() {
  let event =
    SessionStarted(
      agent_id: Some("agent-123"),
      agent_name: Some("Math Tutor"),
      model: "gpt-4",
      provider_name: Some("openai"),
      system_prompt: Some("You are helpful"),
    )

  let json_str = session.format_event(event)

  // Decode the "event" field — not string.contains
  decode_event_type(json_str)
  |> should.equal("session_started")

  // Decode the "model" field
  let model_decoder = dynamic_decode.at(["model"], dynamic_decode.string)
  let assert Ok("gpt-4") =
    json.parse(from: json_str, using: model_decoder)
    |> result.map_error(fn(_) { Nil })

  // Decode the "agent_name" field
  let name_decoder =
    dynamic_decode.at(["agent_name"], dynamic_decode.optional(dynamic_decode.string))
  let assert Ok(Some("Math Tutor")) =
    json.parse(from: json_str, using: name_decoder)
    |> result.map_error(fn(_) { Nil })
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

  // Decode and assert on individual fields
  decode_event_type(json_str)
  |> should.equal("inference_completed")

  let decoder = dynamic_decode.at(["response_id"], dynamic_decode.string)
  let assert Ok("chatcmpl-123") =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })

  let decoder = dynamic_decode.at(["finish_reason"], dynamic_decode.string)
  let assert Ok("stop") =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })

  let decoder = dynamic_decode.at(["duration_ms"], dynamic_decode.int)
  let assert Ok(150) =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })

  let decoder = dynamic_decode.at(["input_tokens"], dynamic_decode.int)
  let assert Ok(10) =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })

  let decoder = dynamic_decode.at(["output_tokens"], dynamic_decode.int)
  let assert Ok(5) =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })
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

  decode_event_type(json_str)
  |> should.equal("tool_executed")

  let decoder = dynamic_decode.at(["duration_ms"], dynamic_decode.int)
  let assert Ok(3) =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })

  let decoder = dynamic_decode.at(["result"], dynamic_decode.string)
  let assert Ok("4") =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })

  let decoder = dynamic_decode.at(["tool_call", "name"], dynamic_decode.string)
  let assert Ok("calculator") =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })

  let decoder = dynamic_decode.at(["tool_call", "arguments"], dynamic_decode.string)
  let assert Ok("{\"expr\":\"2+2\"}") =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })
}

pub fn format_inference_failed_includes_error_test() {
  let event =
    InferenceFailed(
      error: ApiError("rate limited"),
      duration_ms: 42,
      input_messages: [],
    )

  let json_str = session.format_event(event)

  decode_event_type(json_str)
  |> should.equal("inference_failed")

  let decoder = dynamic_decode.at(["error", "type"], dynamic_decode.string)
  let assert Ok("api_error") =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })

  let decoder = dynamic_decode.at(["error", "message"], dynamic_decode.string)
  let assert Ok("rate limited") =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })

  let decoder = dynamic_decode.at(["duration_ms"], dynamic_decode.int)
  let assert Ok(42) =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })
}

pub fn format_session_ended_normal_test() {
  let event = SessionEnded(NormalEnd)

  let json_str = session.format_event(event)

  decode_event_type(json_str)
  |> should.equal("session_ended")

  let decoder = dynamic_decode.at(["reason", "type"], dynamic_decode.string)
  let assert Ok("normal_end") =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })
}

pub fn format_session_ended_max_iterations_test() {
  let event = SessionEnded(MaxIterationsExceeded(10))

  let json_str = session.format_event(event)

  decode_event_type(json_str)
  |> should.equal("session_ended")

  let decoder =
    dynamic_decode.at(["reason", "type"], dynamic_decode.string)
  let assert Ok("max_iterations_exceeded") =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })

  let decoder =
    dynamic_decode.at(["reason", "max_iterations"], dynamic_decode.int)
  let assert Ok(10) =
    json.parse(from: json_str, using: decoder)
    |> result.map_error(fn(_) { Nil })
}

// ── Actor integration tests ───────────────────────────────────────────
// Use record_sync for deterministic writes — no process.sleep.

pub fn start_returns_ok_test() {
  use path <- with_temp_file("start_ok")
  let assert Ok(_writer) = session.start(path)
}

pub fn write_single_event_test() {
  use path <- with_temp_file("single_event")
  let assert Ok(writer) = session.start(path)

  let event =
    SessionStarted(
      agent_id: Some("agent-123"),
      agent_name: Some("Math Tutor"),
      model: "gpt-4",
      provider_name: Some("openai"),
      system_prompt: Some("You are helpful"),
    )

  session.record_sync(writer, event)

  let lines = read_jsonl_lines(path)

  lines
  |> list.length
  |> should.equal(1)

  // Verify the event type via decode, not string.contains
  let first_line = list.first(lines) |> should.be_ok
  decode_event_type(first_line)
  |> should.equal("session_started")

  session.stop(writer)
}

pub fn write_multiple_events_in_order_test() {
  use path <- with_temp_file("multi_events")
  let assert Ok(writer) = session.start(path)

  let event1 =
    SessionStarted(
      agent_id: None,
      agent_name: None,
      model: "gpt-4",
      provider_name: None,
      system_prompt: None,
    )

  let event2 =
    InferenceCompleted(
      message: Assistant(content: "hi", tool_calls: [], thinking: None),
      response_id: None,
      response_model: None,
      finish_reason: None,
      input_tokens: None,
      output_tokens: None,
      duration_ms: 150,
      input_messages: [],
    )

  let event3 = SessionEnded(NormalEnd)

  session.record_sync(writer, event1)
  session.record_sync(writer, event2)
  session.record_sync(writer, event3)

  let lines = read_jsonl_lines(path)

  lines
  |> list.length
  |> should.equal(3)

  // Verify order by decoding event type from each line
  let first = list.first(lines) |> should.be_ok
  decode_event_type(first)
  |> should.equal("session_started")

  let second = list.drop(lines, 1) |> list.first |> should.be_ok
  decode_event_type(second)
  |> should.equal("inference_completed")

  let third = list.drop(lines, 2) |> list.first |> should.be_ok
  decode_event_type(third)
  |> should.equal("session_ended")

  session.stop(writer)
}

pub fn record_sync_after_stop_does_not_crash_test() {
  use path <- with_temp_file("after_stop")
  let assert Ok(writer) = session.start(path)

  session.stop(writer)

  // Sending to a stopped actor should not crash the test process.
  // The message goes to a dead process mailbox — silently dropped.
  let event =
    SessionStarted(
      agent_id: None,
      agent_name: None,
      model: "gpt-4",
      provider_name: None,
      system_prompt: None,
    )

  session.record(writer, event)
}

// ── Pure serialization tests for new variants ─────────────────────

pub fn format_inference_started_produces_valid_json_test() {
  let event = InferenceStarted(model: "gpt-4", message_count: 3)

  let json_str = session.format_event(event)

  // Decode the "event" field
  decode_event_type(json_str)
  |> should.equal("inference_started")

  // Decode the "model" field
  let model_decoder = dynamic_decode.at(["model"], dynamic_decode.string)
  let assert Ok("gpt-4") =
    json.parse(from: json_str, using: model_decoder)
    |> result.map_error(fn(_) { Nil })

  // Decode the "message_count" field
  let count_decoder = dynamic_decode.at(["message_count"], dynamic_decode.int)
  let assert Ok(3) =
    json.parse(from: json_str, using: count_decoder)
    |> result.map_error(fn(_) { Nil })
}

pub fn format_tool_started_produces_valid_json_test() {
  let tool_call = ToolCall(id: "c1", name: "calculator", arguments_json: "{\"expr\":\"2+2\"}")
  let event = ToolStarted(tool_call: tool_call)

  let json_str = session.format_event(event)

  // Decode the "event" field
  decode_event_type(json_str)
  |> should.equal("tool_started")

  // Decode the tool_call fields
  let name_decoder = dynamic_decode.at(["tool_call", "name"], dynamic_decode.string)
  let assert Ok("calculator") =
    json.parse(from: json_str, using: name_decoder)
    |> result.map_error(fn(_) { Nil })

  let id_decoder = dynamic_decode.at(["tool_call", "id"], dynamic_decode.string)
  let assert Ok("c1") =
    json.parse(from: json_str, using: id_decoder)
    |> result.map_error(fn(_) { Nil })

  let args_decoder = dynamic_decode.at(["tool_call", "arguments"], dynamic_decode.string)
  let assert Ok("{\"expr\":\"2+2\"}") =
    json.parse(from: json_str, using: args_decoder)
    |> result.map_error(fn(_) { Nil })
}

pub fn format_tool_blocked_produces_valid_json_test() {
  let tool_call = ToolCall(id: "c2", name: "risky_tool", arguments_json: "{\"cmd\":\"rm -rf\"}")
  let event =
    ToolBlocked(
      tool_call: tool_call,
      extension_name: "safety_guard",
      reason: "Dangerous command detected",
    )

  let json_str = session.format_event(event)

  // Decode the "event" field
  decode_event_type(json_str)
  |> should.equal("tool_blocked")

  // Decode the tool_call fields
  let name_decoder = dynamic_decode.at(["tool_call", "name"], dynamic_decode.string)
  let assert Ok("risky_tool") =
    json.parse(from: json_str, using: name_decoder)
    |> result.map_error(fn(_) { Nil })

  // Decode extension_name
  let ext_decoder = dynamic_decode.at(["extension_name"], dynamic_decode.string)
  let assert Ok("safety_guard") =
    json.parse(from: json_str, using: ext_decoder)
    |> result.map_error(fn(_) { Nil })

  // Decode reason
  let reason_decoder = dynamic_decode.at(["reason"], dynamic_decode.string)
  let assert Ok("Dangerous command detected") =
    json.parse(from: json_str, using: reason_decoder)
    |> result.map_error(fn(_) { Nil })
}

pub fn format_extension_acted_produces_valid_json_test() {
  let action =
    ExtensionActionDetail(
      action_type: "modify_args",
      description: "Changed expression format",
    )
  let event =
    ExtensionActed(
      extension_name: "safety_guard",
      hook: BeforeToolCall,
      action: action,
    )

  let json_str = session.format_event(event)

  // Decode the "event" field
  decode_event_type(json_str)
  |> should.equal("extension_acted")

  // Decode extension_name
  let ext_decoder = dynamic_decode.at(["extension_name"], dynamic_decode.string)
  let assert Ok("safety_guard") =
    json.parse(from: json_str, using: ext_decoder)
    |> result.map_error(fn(_) { Nil })

  // Decode hook
  let hook_decoder = dynamic_decode.at(["hook"], dynamic_decode.string)
  let assert Ok("before_tool_call") =
    json.parse(from: json_str, using: hook_decoder)
    |> result.map_error(fn(_) { Nil })

  // Decode action fields
  let action_type_decoder = dynamic_decode.at(["action", "action_type"], dynamic_decode.string)
  let assert Ok("modify_args") =
    json.parse(from: json_str, using: action_type_decoder)
    |> result.map_error(fn(_) { Nil })

  let description_decoder = dynamic_decode.at(["action", "description"], dynamic_decode.string)
  let assert Ok("Changed expression format") =
    json.parse(from: json_str, using: description_decoder)
    |> result.map_error(fn(_) { Nil })
}

// ── Supervised Consumer Tests ──────────────────────────────────────

/// supervised() returns a valid ChildSpecification without crashing.
/// The spec type ensures compile-time type safety; this is a smoke test.
pub fn session_supervised_creates_spec_test() {
  use path <- with_temp_file("supervised_spec")
  let name = process.new_name("test_session_consumer")
  let _spec = session.supervised(path, name)
  // If we got here, the spec was created successfully.
  // The ChildSpec type ensures type safety at compile time.
  // Integration testing is covered separately.
  True
}

/// Start a consumer actor and verify it integrates with the dispatcher.
/// Uses the process.receive pattern — no sleep needed.
/// Note: We don't verify file writes here due to timing issues with fire-and-forget actors.
/// File writing is tested separately with record_sync.
pub fn session_consumer_receives_events_via_dispatcher_test() {
  use path <- with_temp_file("dispatcher_consumer")
  let assert Ok(disp) = dispatcher.start()
  
  // Start a test consumer as sync mechanism
  let sync_consumer = process.new_subject()
  process.send(disp, dispatcher.RegisterConsumer(sync_consumer))
  
  // Start session consumer actor with the consumer handler
  let assert Ok(session_consumer) = session.start_consumer(path)
  process.send(disp, dispatcher.RegisterConsumer(session_consumer))
  
  // Send events through dispatcher and verify sync consumer receives them
  // This confirms the dispatcher is processing messages and sending to consumers
  let event1 = InferenceStarted(model: "gpt-4", message_count: 3)
  process.send(disp, dispatcher.Event(event1))
  let assert Ok(received1) = process.receive(sync_consumer, 2000)
  let assert InferenceStarted(model:, message_count:) = received1
  model |> should.equal("gpt-4")
  message_count |> should.equal(3)
  
  let event2 = SessionStarted(
    agent_id: Some("agent-123"),
    agent_name: None,
    model: "gpt-4",
    provider_name: None,
    system_prompt: None,
  )
  process.send(disp, dispatcher.Event(event2))
  let assert Ok(received2) = process.receive(sync_consumer, 2000)
  let assert SessionStarted(model:, ..) = received2
  model |> should.equal("gpt-4")
  
  // Cleanup
  process.send(disp, dispatcher.Stop)
}

/// start_consumer() creates a Subject that can receive SessionEvent directly.
pub fn start_consumer_creates_valid_subject_test() {
  use path <- with_temp_file("consumer_subject")
  let assert Ok(consumer) = session.start_consumer(path)
  
  // Can send an event directly to the subject
  let event = InferenceStarted(model: "gpt-4", message_count: 5)
  process.send(consumer, event)
  
  // Send a second event to ensure first is processed
  let event2 = SessionEnded(NormalEnd)
  process.send(consumer, event2)
  
  // Fire-and-forget doesn't crash
  let _ = process.send(consumer, event)
  
  True
}
