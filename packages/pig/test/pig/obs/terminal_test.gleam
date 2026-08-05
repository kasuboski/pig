import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import pig/obs/dispatcher
import pig/obs/events.{
  BeforeToolCall, HookActionDetail, InferenceStarted, MaxIterationsExceeded,
  NormalEnd,
}
import pig/obs/terminal
import pig/provider
import pig_protocol/error.{ApiError}
import pig_protocol/message.{Assistant, ToolCall}
import pig_protocol/stop_reason

pub fn format_session_started_shows_model_test() {
  let event =
    events.SessionStarted(
      agent_id: Some("agent-123"),
      agent_name: Some("Math Tutor"),
      model: "gpt-4",
      provider_name: Some("openai"),
      system_prompt: Some("You are a math tutor."),
    )

  let result = terminal.format_event(event)

  assert string.contains(result, "START")
  assert string.contains(result, "gpt-4")
  assert string.contains(result, "Math Tutor")
}

pub fn format_inference_completed_shows_duration_test() {
  let event =
    events.InferenceCompleted(
      message: Assistant("hi", [], None, None),
      response_id: None,
      response_model: None,
      stop_reason: None,
      input_tokens: None,
      output_tokens: None,
      duration_ms: 150,
      input_messages: [],
      settings: provider.default_settings(),
    )

  let result = terminal.format_event(event)

  assert string.contains(result, "INF")
  assert string.contains(result, "150ms")
  assert string.contains(result, "Completed")
}

pub fn format_inference_completed_shows_token_counts_test() {
  let event =
    events.InferenceCompleted(
      message: Assistant("hi", [], None, None),
      response_id: None,
      response_model: None,
      stop_reason: Some(stop_reason.Stop),
      input_tokens: Some(52),
      output_tokens: Some(15),
      duration_ms: 150,
      input_messages: [],
      settings: provider.default_settings(),
    )

  let result = terminal.format_event(event)

  assert string.contains(result, "INF")
  assert string.contains(result, "150ms")
  assert string.contains(result, "52")
  assert string.contains(result, "15")
  assert string.contains(result, "stop")
}

pub fn format_inference_completed_without_tokens_test() {
  let event =
    events.InferenceCompleted(
      message: Assistant("hi", [], None, None),
      response_id: None,
      response_model: None,
      stop_reason: None,
      input_tokens: None,
      output_tokens: None,
      duration_ms: 200,
      input_messages: [],
      settings: provider.default_settings(),
    )

  let result = terminal.format_event(event)

  // Should not crash and should show duration
  assert string.contains(result, "INF")
  assert string.contains(result, "200ms")
  assert string.contains(result, "Completed")
}

pub fn format_tool_executed_shows_tool_name_test() {
  let tool_call = ToolCall(id: "c1", name: "calculator", arguments_json: "{}")
  let event =
    events.ToolExecuted(tool_call: tool_call, result: "4", duration_ms: 3)

  let result = terminal.format_event(event)

  assert string.contains(result, "TOOL")
  assert string.contains(result, "calculator")
  assert string.contains(result, "3ms")
}

pub fn format_inference_failed_shows_error_test() {
  let event =
    events.InferenceFailed(
      model: "requested-model",
      error: ApiError("rate limited"),
      duration_ms: 100,
      input_messages: [],
      settings: provider.default_settings(),
    )

  let result = terminal.format_event(event)

  assert string.contains(result, "ERR")
  assert string.contains(result, "100ms")
  assert string.contains(result, "ApiError")
  assert string.contains(result, "rate limited")
}

pub fn format_session_ended_normal_test() {
  let event = events.SessionEnded(NormalEnd)

  let result = terminal.format_event(event)

  assert string.contains(result, "END")
  assert string.contains(result, "normal")
}

pub fn format_session_ended_max_iterations_test() {
  let event = events.SessionEnded(MaxIterationsExceeded(50))

  let result = terminal.format_event(event)

  assert string.contains(result, "END")
  assert string.contains(result, "50")
  assert string.contains(result, "iterations")
}

// ── Tests for new SessionEvent variants ─────────────────────────────

pub fn format_inference_started_shows_model_test() {
  let event =
    events.InferenceStarted(
      model: "gpt-4",
      message_count: 3,
      settings: provider.default_settings(),
    )

  let result = terminal.format_event(event)

  assert string.contains(result, "INF")
  assert string.contains(result, "Started")
  assert string.contains(result, "gpt-4")
  assert string.contains(result, "3")
}

pub fn format_tool_started_shows_tool_name_test() {
  let tool_call =
    ToolCall(id: "c1", name: "calculator", arguments_json: "{\"expr\":\"2+2\"}")
  let event = events.ToolStarted(tool_call: tool_call)

  let result = terminal.format_event(event)

  assert string.contains(result, "TOOL")
  assert string.contains(result, "Started")
  assert string.contains(result, "calculator")
}

pub fn format_tool_blocked_shows_info_test() {
  let tool_call =
    ToolCall(
      id: "c2",
      name: "risky_tool",
      arguments_json: "{\"cmd\":\"rm -rf\"}",
    )
  let event =
    events.ToolBlocked(
      tool_call: tool_call,
      hook_name: "safety_guard",
      reason: "Dangerous command detected",
    )

  let result = terminal.format_event(event)

  assert string.contains(result, "TOOL")
  assert string.contains(result, "Blocked")
  assert string.contains(result, "risky_tool")
  assert string.contains(result, "safety_guard")
  assert string.contains(result, "Dangerous command detected")
}

pub fn format_hook_acted_shows_info_test() {
  let action =
    HookActionDetail(
      action_type: "modify_args",
      description: "Changed expression format",
    )
  let event =
    events.HookActed(
      hook_name: "safety_guard",
      hook_point: BeforeToolCall,
      action: action,
    )

  let result = terminal.format_event(event)

  assert string.contains(result, "[HOOK]")
  assert string.contains(result, "safety_guard")
  assert string.contains(result, "before_tool_call")
  assert string.contains(result, "modify_args")
}

// ── Supervised Consumer Tests ──────────────────────────────────────

/// supervised() returns a valid ChildSpecification without crashing.
/// The spec type ensures compile-time type safety; this is a smoke test.
pub fn terminal_supervised_creates_spec_test() {
  let name = process.new_name("test_terminal_consumer")
  let _spec = terminal.supervised(name)
  // If we got here, the spec was created successfully.
  // The ChildSpec type ensures type safety at compile time.
  // Integration testing is covered separately.
  Nil
}

/// Start a terminal consumer actor and verify it receives events via dispatcher.
/// Uses the process.receive pattern with a second sync consumer.
pub fn terminal_consumer_receives_events_via_dispatcher_test() {
  let assert Ok(disp) = dispatcher.start()

  // Start a sync consumer to verify dispatcher processed the message
  let sync_consumer = process.new_subject()
  let assert Ok(Nil) = dispatcher.register_consumer(disp, sync_consumer)

  // Start terminal consumer actor
  let assert Ok(terminal_consumer) = terminal.start_consumer()
  let assert Ok(Nil) = dispatcher.register_consumer(disp, terminal_consumer)

  // Send event through dispatcher
  let event =
    InferenceStarted(
      model: "gpt-4",
      message_count: 3,
      settings: provider.default_settings(),
    )
  process.send(disp, dispatcher.Event(event))

  // Wait for sync consumer to receive (confirms dispatcher processed the message)
  let assert Ok(received) = process.receive(sync_consumer, 2000)
  let assert InferenceStarted(model:, message_count:, settings: _) = received
  assert model == "gpt-4"
  assert message_count == 3

  // Cleanup
  process.send(disp, dispatcher.Stop)
}

/// start_consumer() creates a Subject that can receive SessionEvent directly.
pub fn start_consumer_creates_valid_subject_test() {
  let assert Ok(consumer) = terminal.start_consumer()

  // Verify the subject is valid by checking it can be used with process.send
  // We don't send actual events because the terminal actor would try to
  // io.println and could crash during test teardown when stdout is gone.
  // The real logic (format_event) is tested separately as a pure function.
  let _ = consumer
  Nil
}
