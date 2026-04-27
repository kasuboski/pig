import pig/obs/events.{NormalEnd, MaxIterationsExceeded}
import pig/obs/terminal
import pig/ai/error.{ApiError}
import pig/ai/message.{Assistant, ToolCall}
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub fn format_session_started_shows_model_test() {
  let event = events.SessionStarted(
    agent_id: Some("agent-123"),
    agent_name: Some("Math Tutor"),
    model: "gpt-4",
    provider_name: Some("openai"),
    system_prompt: Some("You are a math tutor."),
  )

  let result = terminal.format_event(event)

  string.contains(result, "START") |> should.be_true
  string.contains(result, "gpt-4") |> should.be_true
  string.contains(result, "Math Tutor") |> should.be_true
}

pub fn format_inference_completed_shows_duration_test() {
  let event = events.InferenceCompleted(
    message: Assistant("hi", [], None),
    response_id: None,
    response_model: None,
    finish_reason: None,
    input_tokens: None,
    output_tokens: None,
    duration_ms: 150,
    input_messages: [],
  )

  let result = terminal.format_event(event)

  string.contains(result, "INF") |> should.be_true
  string.contains(result, "150ms") |> should.be_true
  string.contains(result, "Completed") |> should.be_true
}

pub fn format_inference_completed_shows_token_counts_test() {
  let event = events.InferenceCompleted(
    message: Assistant("hi", [], None),
    response_id: None,
    response_model: None,
    finish_reason: Some("stop"),
    input_tokens: Some(52),
    output_tokens: Some(15),
    duration_ms: 150,
    input_messages: [],
  )

  let result = terminal.format_event(event)

  string.contains(result, "INF") |> should.be_true
  string.contains(result, "150ms") |> should.be_true
  string.contains(result, "52") |> should.be_true
  string.contains(result, "15") |> should.be_true
  string.contains(result, "stop") |> should.be_true
}

pub fn format_inference_completed_without_tokens_test() {
  let event = events.InferenceCompleted(
    message: Assistant("hi", [], None),
    response_id: None,
    response_model: None,
    finish_reason: None,
    input_tokens: None,
    output_tokens: None,
    duration_ms: 200,
    input_messages: [],
  )

  let result = terminal.format_event(event)

  // Should not crash and should show duration
  string.contains(result, "INF") |> should.be_true
  string.contains(result, "200ms") |> should.be_true
  string.contains(result, "Completed") |> should.be_true
}

pub fn format_tool_executed_shows_tool_name_test() {
  let tool_call = ToolCall(id: "c1", name: "calculator", arguments_json: "{}")
  let event = events.ToolExecuted(
    tool_call: tool_call,
    result: "4",
    duration_ms: 3,
  )

  let result = terminal.format_event(event)

  string.contains(result, "TOOL") |> should.be_true
  string.contains(result, "calculator") |> should.be_true
  string.contains(result, "3ms") |> should.be_true
}

pub fn format_inference_failed_shows_error_test() {
  let event = events.InferenceFailed(
    error: ApiError("rate limited"),
    duration_ms: 100,
    input_messages: [],
  )

  let result = terminal.format_event(event)

  string.contains(result, "ERR") |> should.be_true
  string.contains(result, "100ms") |> should.be_true
  string.contains(result, "ApiError") |> should.be_true
  string.contains(result, "rate limited") |> should.be_true
}

pub fn format_session_ended_normal_test() {
  let event = events.SessionEnded(NormalEnd)

  let result = terminal.format_event(event)

  string.contains(result, "END") |> should.be_true
  string.contains(result, "normal") |> should.be_true
}

pub fn format_session_ended_max_iterations_test() {
  let event = events.SessionEnded(MaxIterationsExceeded(50))

  let result = terminal.format_event(event)

  string.contains(result, "END") |> should.be_true
  string.contains(result, "50") |> should.be_true
  string.contains(result, "iterations") |> should.be_true
}
