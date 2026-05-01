import gleeunit
import gleeunit/should
import gleam/erlang/process
import gleam/option.{Some}
import pig/ai/error.{ApiError}
import pig/ai/message.{ToolCall, User}
import pig/obs/dispatcher
import pig/obs/events.{
  SessionStarted,
  InferenceStarted,
  InferenceCompleted,
  ToolStarted,
  ToolExecuted,
  ToolBlocked,
  HookActed,
  InferenceFailed,
  SessionEnded,
  BeforeToolCall,
  HookActionDetail,
  NormalEnd,
}
import pig/obs/listener

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
  process.send(dispatcher_subject, dispatcher.RegisterConsumer(consumer_subject))
  #(#(dispatcher_subject, consumer_subject), fn() {
    process.send(dispatcher_subject, dispatcher.Stop)
  })
}

fn setup_with_listener() {
  let listener_handle = listener.attach()
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let consumer_subject = process.new_subject()
  process.send(dispatcher_subject, dispatcher.RegisterConsumer(consumer_subject))
  #(
    #(dispatcher_subject, consumer_subject, listener_handle),
    fn() {
      listener.detach(listener_handle)
      process.send(dispatcher_subject, dispatcher.Stop)
    },
  )
}

// ── Telemetry Projection Tests ─────────────────────────────────────────
// Pattern: register consumer → send event → receive on consumer (confirms
// telemetry already fired) → assert on listener data. No sleep.

pub fn dispatcher_emits_inference_start_telemetry_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let event = InferenceStarted(model: "gpt-4", message_count: 3)
  send_and_confirm(disp, event, consumer)

  let captured = listener.get_events(handle)
  let assert [events.InferenceStart(model:, message_count:)] = captured
  model |> should.equal("gpt-4")
  message_count |> should.equal(3)

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
      finish_reason: Some("stop"),
      input_tokens: Some(100),
      output_tokens: Some(50),
      duration_ms: 150,
      input_messages: [message],
    )
  send_and_confirm(disp, event, consumer)

  let captured = listener.get_events(handle)
  let assert [events.InferenceStop(model:, duration_ms:, ..)] = captured
  model |> should.equal("gpt-4")
  duration_ms |> should.equal(150)

  cleanup()
}

pub fn dispatcher_emits_tool_start_telemetry_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let tool_call =
    ToolCall(id: "call_123", name: "calculator", arguments_json: "{\"expr\":\"2+2\"}")
  let event = ToolStarted(tool_call:)
  send_and_confirm(disp, event, consumer)

  let captured = listener.get_events(handle)
  let assert [events.ToolStart(tool_name:, tool_call_id:, arguments_json:)] = captured
  tool_name |> should.equal("calculator")
  tool_call_id |> should.equal("call_123")
  arguments_json |> should.equal("{\"expr\":\"2+2\"}")

  cleanup()
}

pub fn dispatcher_emits_tool_stop_telemetry_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let tool_call =
    ToolCall(id: "call_123", name: "calculator", arguments_json: "{\"expr\":\"2+2\"}")
  let event =
    ToolExecuted(tool_call:, result: "{\"result\":4}", duration_ms: 42)
  send_and_confirm(disp, event, consumer)

  let captured = listener.get_events(handle)
  let assert [events.ToolStop(tool_name:, tool_call_id:, duration_ms:, ..)] = captured
  tool_name |> should.equal("calculator")
  tool_call_id |> should.equal("call_123")
  duration_ms |> should.equal(42)

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
  first_name |> should.equal(events.tool_blocked_name())

  cleanup()
}

pub fn dispatcher_emits_inference_exception_telemetry_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let event =
    InferenceFailed(
      error: ApiError(message: "Test error"),
      duration_ms: 150,
      input_messages: [User(content: "test")],
    )
  send_and_confirm(disp, event, consumer)

  let captured = listener.get_events(handle)
  let assert [events.InferenceException(model:, error_type:, ..)] = captured
  model |> should.equal("unknown")
  error_type |> should.equal("api_error")

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

  listener.get_events(handle) |> should.equal([])

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

  listener.get_events(handle) |> should.equal([])

  cleanup()
}

pub fn dispatcher_does_not_emit_telemetry_for_session_ended_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let event = SessionEnded(reason: NormalEnd)
  send_and_confirm(disp, event, consumer)

  listener.get_events(handle) |> should.equal([])

  cleanup()
}

// ── Consumer Fan-Out Tests ─────────────────────────────────────────────
// Already use process.receive — no sleep needed.

pub fn dispatcher_fans_out_to_registered_consumer_test() {
  let #(#(disp, consumer), cleanup) = setup()

  let event = InferenceStarted(model: "gpt-4", message_count: 3)
  let received = send_and_confirm(disp, event, consumer)

  let assert InferenceStarted(model:, message_count:) = received
  model |> should.equal("gpt-4")
  message_count |> should.equal(3)

  cleanup()
}

pub fn dispatcher_fans_out_to_multiple_consumers_test() {
  let assert Ok(disp) = dispatcher.start()
  let c1 = process.new_subject()
  let c2 = process.new_subject()
  process.send(disp, dispatcher.RegisterConsumer(c1))
  process.send(disp, dispatcher.RegisterConsumer(c2))

  let event = InferenceStarted(model: "gpt-4", message_count: 3)
  process.send(disp, dispatcher.Event(event))

  let assert Ok(r1) = process.receive(c1, 2000)
  let assert Ok(r2) = process.receive(c2, 2000)
  r1 |> should.equal(event)
  r2 |> should.equal(event)

  process.send(disp, dispatcher.Stop)
}

// ── Dynamic Registration Tests ─────────────────────────────────────────

pub fn dispatcher_supports_dynamic_registration_test() {
  let assert Ok(disp) = dispatcher.start()

  // Event before any consumer — no one to receive
  let event1 = InferenceStarted(model: "gpt-4", message_count: 3)
  process.send(disp, dispatcher.Event(event1))

  // Now register consumer
  let consumer = process.new_subject()
  process.send(disp, dispatcher.RegisterConsumer(consumer))

  // Second event — consumer should receive it
  let event2 = InferenceStarted(model: "gpt-3.5", message_count: 2)
  let received = send_and_confirm(disp, event2, consumer)

  let assert InferenceStarted(model:, message_count:) = received
  model |> should.equal("gpt-3.5")
  message_count |> should.equal(2)

  process.send(disp, dispatcher.Stop)
}

// ── Dead Consumer Resilience Tests ─────────────────────────────────────

pub fn dispatcher_does_not_crash_on_dead_consumer_test() {
  let assert Ok(disp) = dispatcher.start()

  // Register a consumer that we'll abandon (no process listening)
  let dead_consumer = process.new_subject()
  process.send(disp, dispatcher.RegisterConsumer(dead_consumer))

  // Send event — dispatcher should not crash
  let event = InferenceStarted(model: "gpt-4", message_count: 3)
  process.send(disp, dispatcher.Event(event))

  // Register a new consumer and confirm dispatcher is still alive
  let live_consumer = process.new_subject()
  process.send(disp, dispatcher.RegisterConsumer(live_consumer))

  let event2 = InferenceStarted(model: "gpt-3.5", message_count: 2)
  let received = send_and_confirm(disp, event2, live_consumer)

  let assert InferenceStarted(model:, message_count:) = received
  model |> should.equal("gpt-3.5")
  message_count |> should.equal(2)

  process.send(disp, dispatcher.Stop)
}
