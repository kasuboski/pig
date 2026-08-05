import gleam/erlang/process
import gleam/option.{Some}
import gleeunit
import pig/obs/dispatcher
import pig/obs/events.{
  BeforeToolCall, HookActed, HookActionDetail, InferenceCompleted,
  InferenceFailed, InferenceStarted, NormalEnd, SessionEnded, SessionStarted,
  ToolBlocked, ToolExecuted, ToolStarted,
}
import pig/obs/listener
import pig/provider
import pig_protocol/error.{ApiError}
import pig_protocol/message.{ToolCall, User}
import pig_protocol/stop_reason
import pig_protocol/thinking

pub fn main() {
  gleeunit.main()
}

// ── Test helpers ──────────────────────────────────────────────────────

/// Send an event to the dispatcher and synchronously confirm it was
/// processed by receiving the fanned-out copy on a test consumer.
///
/// The dispatcher handler emits telemetry BEFORE fan-out, so once the
/// consumer receives the event, telemetry is guaranteed to have fired.
/// No `process.sleep` needed.
fn send_and_confirm(
  dispatcher_subject: process.Subject(dispatcher.DispatcherMessage),
  event: events.SessionEvent,
  consumer_subject: process.Subject(events.SessionEvent),
) -> events.SessionEvent {
  process.send(dispatcher_subject, dispatcher.Event(event))
  let assert Ok(received) = process.receive(consumer_subject, 2000)
  received
}

/// Wire up a dispatcher + test consumer + optional telemetry listener.
/// Returns the three handles for use in tests.
fn setup() {
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let consumer_subject = process.new_subject()
  dispatcher.register_consumer(dispatcher_subject, consumer_subject)
  #(#(dispatcher_subject, consumer_subject), fn() {
    process.send(dispatcher_subject, dispatcher.Stop)
  })
}

fn setup_with_listener() {
  let listener_handle = listener.attach()
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let consumer_subject = process.new_subject()
  dispatcher.register_consumer(dispatcher_subject, consumer_subject)
  #(#(dispatcher_subject, consumer_subject, listener_handle), fn() {
    listener.detach(listener_handle)
    process.send(dispatcher_subject, dispatcher.Stop)
  })
}

// ── Telemetry Projection Tests ─────────────────────────────────────────
// Pattern: register consumer → send event → receive on consumer (confirms
// telemetry already fired) → assert on listener data. No sleep.

pub fn dispatcher_emits_inference_start_telemetry_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let requested = provider.with_thinking_level(thinking.Off)
  let event =
    InferenceStarted(model: "gpt-4", message_count: 3, settings: requested)
  send_and_confirm(disp, event, consumer)

  let captured = listener.get_events(handle)
  let assert [events.InferenceStart(model:, message_count:, settings:)] =
    captured
  assert model == "gpt-4"
  assert message_count == 3
  assert settings == requested

  cleanup()
}

pub fn dispatcher_emits_inference_stop_telemetry_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let message = User(content: "test")
  let event =
    InferenceCompleted(
      message:,
      response_id: Some("resp-123"),
      response_model: Some("gpt-4"),
      stop_reason: Some(stop_reason.Stop),
      input_tokens: Some(100),
      output_tokens: Some(50),
      duration_ms: 150,
      input_messages: [message],
      settings: provider.default_settings(),
    )
  send_and_confirm(disp, event, consumer)

  let captured = listener.get_events(handle)
  let assert [events.InferenceStop(model:, duration_ms:, ..)] = captured
  assert model == "gpt-4"
  assert duration_ms == 150

  cleanup()
}

pub fn dispatcher_emits_tool_start_telemetry_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let tool_call =
    ToolCall(
      id: "call_123",
      name: "calculator",
      arguments_json: "{\"expr\":\"2+2\"}",
    )
  let event = ToolStarted(tool_call:)
  send_and_confirm(disp, event, consumer)

  let captured = listener.get_events(handle)
  let assert [events.ToolStart(tool_name:, tool_call_id:, arguments_json:)] =
    captured
  assert tool_name == "calculator"
  assert tool_call_id == "call_123"
  assert arguments_json == "{\"expr\":\"2+2\"}"

  cleanup()
}

pub fn dispatcher_emits_tool_stop_telemetry_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let tool_call =
    ToolCall(
      id: "call_123",
      name: "calculator",
      arguments_json: "{\"expr\":\"2+2\"}",
    )
  let event =
    ToolExecuted(tool_call:, result: "{\"result\":4}", duration_ms: 42)
  send_and_confirm(disp, event, consumer)

  let captured = listener.get_events(handle)
  let assert [events.ToolStop(tool_name:, tool_call_id:, duration_ms:, ..)] =
    captured
  assert tool_name == "calculator"
  assert tool_call_id == "call_123"
  assert duration_ms == 42

  cleanup()
}

pub fn dispatcher_emits_tool_blocked_telemetry_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let tool_call =
    ToolCall(id: "call_123", name: "calculator", arguments_json: "{}")
  let event =
    ToolBlocked(
      tool_call:,
      hook_name: "safety_guard",
      reason: "Disallowed characters",
    )
  send_and_confirm(disp, event, consumer)

  let names = listener.get_event_names(handle)
  let assert [first_name] = names
  assert first_name == events.tool_blocked_name()

  cleanup()
}

pub fn dispatcher_emits_inference_exception_telemetry_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let event =
    InferenceFailed(
      model: "requested-model",
      error: ApiError(message: "Test error"),
      duration_ms: 150,
      input_messages: [User(content: "test")],
      settings: provider.default_settings(),
    )
  send_and_confirm(disp, event, consumer)

  let captured = listener.get_events(handle)
  let assert [events.InferenceException(model:, error_type:, ..)] = captured
  assert model == "requested-model"
  assert error_type == "api_error"

  cleanup()
}

// ── No Telemetry Projection Tests ──────────────────────────────────────

pub fn dispatcher_does_not_emit_telemetry_for_session_started_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let event =
    SessionStarted(
      agent_id: Some("agent-123"),
      agent_name: Some("TestAgent"),
      model: "gpt-4",
      provider_name: Some("openai"),
      system_prompt: Some("You are helpful."),
    )
  send_and_confirm(disp, event, consumer)

  assert listener.get_events(handle) == []

  cleanup()
}

pub fn dispatcher_does_not_emit_telemetry_for_hook_acted_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let event =
    HookActed(
      hook_name: "safety_guard",
      hook_point: BeforeToolCall,
      action: HookActionDetail("modify_args", "Changed format"),
    )
  send_and_confirm(disp, event, consumer)

  assert listener.get_events(handle) == []

  cleanup()
}

pub fn dispatcher_does_not_emit_telemetry_for_session_ended_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let event = SessionEnded(reason: NormalEnd)
  send_and_confirm(disp, event, consumer)

  assert listener.get_events(handle) == []

  cleanup()
}

// ── Consumer Fan-Out Tests ─────────────────────────────────────────────
// Already use process.receive — no sleep needed.

pub fn dispatcher_fans_out_to_registered_consumer_test() {
  let #(#(disp, consumer), cleanup) = setup()

  let event =
    InferenceStarted(
      model: "gpt-4",
      message_count: 3,
      settings: provider.default_settings(),
    )
  let received = send_and_confirm(disp, event, consumer)

  let assert InferenceStarted(model:, message_count:, settings: _) = received
  assert model == "gpt-4"
  assert message_count == 3

  cleanup()
}

pub fn dispatcher_fans_out_to_multiple_consumers_test() {
  let assert Ok(disp) = dispatcher.start()
  let c1 = process.new_subject()
  let c2 = process.new_subject()
  dispatcher.register_consumer(disp, c1)
  dispatcher.register_consumer(disp, c2)

  let event =
    InferenceStarted(
      model: "gpt-4",
      message_count: 3,
      settings: provider.default_settings(),
    )
  process.send(disp, dispatcher.Event(event))

  let assert Ok(r1) = process.receive(c1, 2000)
  let assert Ok(r2) = process.receive(c2, 2000)
  assert r1 == event
  assert r2 == event

  process.send(disp, dispatcher.Stop)
}

// ── Dynamic Registration Tests ─────────────────────────────────────────

pub fn dispatcher_supports_dynamic_registration_test() {
  let assert Ok(disp) = dispatcher.start()

  // Event before any consumer — no one to receive
  let event1 =
    InferenceStarted(
      model: "gpt-4",
      message_count: 3,
      settings: provider.default_settings(),
    )
  process.send(disp, dispatcher.Event(event1))

  // Now register consumer
  let consumer = process.new_subject()
  dispatcher.register_consumer(disp, consumer)

  // Second event — consumer should receive it
  let event2 =
    InferenceStarted(
      model: "gpt-3.5",
      message_count: 2,
      settings: provider.default_settings(),
    )
  let received = send_and_confirm(disp, event2, consumer)

  let assert InferenceStarted(model:, message_count:, settings: _) = received
  assert model == "gpt-3.5"
  assert message_count == 2

  process.send(disp, dispatcher.Stop)
}

// ── Dead Consumer Resilience Tests ─────────────────────────────────────

pub fn dispatcher_does_not_crash_on_dead_consumer_test() {
  let assert Ok(disp) = dispatcher.start()

  // Register a consumer that we'll abandon (no process listening)
  let dead_consumer = process.new_subject()
  dispatcher.register_consumer(disp, dead_consumer)

  // Send event — dispatcher should not crash
  let event =
    InferenceStarted(
      model: "gpt-4",
      message_count: 3,
      settings: provider.default_settings(),
    )
  process.send(disp, dispatcher.Event(event))

  // Register a new consumer and confirm dispatcher is still alive
  let live_consumer = process.new_subject()
  dispatcher.register_consumer(disp, live_consumer)

  let event2 =
    InferenceStarted(
      model: "gpt-3.5",
      message_count: 2,
      settings: provider.default_settings(),
    )
  let received = send_and_confirm(disp, event2, live_consumer)

  let assert InferenceStarted(model:, message_count:, settings: _) = received
  assert model == "gpt-3.5"
  assert message_count == 2

  process.send(disp, dispatcher.Stop)
}
