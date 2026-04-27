//// Terminal pretty printer for SessionEvents.
////
//// OTP actor that receives SessionEvents and prints formatted output.
//// Pure `format_event` function for testing without side effects.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{None, Some}
import gleam/otp/actor
import pig/ai/error.{type AiError, ApiError, RateLimited, Timeout, InvalidResponse}
import pig/obs/events.{type SessionEvent, type SessionEndReason, NormalEnd, ErrorEnd, MaxIterationsExceeded, Interrupted}
import gleam/io

// ── State ─────────────────────────────────────────────────────────────

/// The printer actor has no state to maintain.
type State {
  State
}

// ── Format Function (Pure, Testable) ────────────────────────────────────

/// Format a SessionEvent as a human-readable string.
/// This function is pure and has no side effects, making it easy to test.
pub fn format_event(event: SessionEvent) -> String {
  case event {
    events.SessionStarted(
      agent_name:,
      model:,
      provider_name: _,
      system_prompt: _,
      agent_id: _,
    ) -> {
      let agent_part = case agent_name {
        Some(name) -> " | agent: " <> name
        None -> ""
      }
      "[START] Session started | model: " <> model <> agent_part
    }

    events.InferenceCompleted(
      message: _,
      response_id: _,
      response_model: _,
      finish_reason:,
      input_tokens:,
      output_tokens:,
      duration_ms:,
      input_messages: _,
    ) -> {
      let duration_str = int.to_string(duration_ms) <> "ms"
      let token_part = case input_tokens, output_tokens {
        Some(input), Some(output) -> {
          " | tokens: " <> int.to_string(input) <> "→"
          <> int.to_string(output)
        }
        _, _ -> ""
      }
      let finish_part = case finish_reason {
        Some(reason) -> " | finish: " <> reason
        None -> ""
      }
      "[INF] Completed | " <> duration_str <> token_part <> finish_part
    }

    events.ToolExecuted(tool_call:, result: _, duration_ms:) -> {
      let duration_str = int.to_string(duration_ms) <> "ms"
      "[TOOL] " <> tool_call.name <> " | " <> duration_str
    }

    events.InferenceFailed(
      error:,
      duration_ms:,
      input_messages: _,
    ) -> {
      let duration_str = int.to_string(duration_ms) <> "ms"
      let error_str = format_error(error)
      "[ERR] Inference failed | " <> duration_str <> " | " <> error_str
    }

    events.SessionEnded(reason) -> {
      "[END] Session ended | " <> format_end_reason(reason)
    }
  }
}

/// Format an AiError for display.
fn format_error(error: AiError) -> String {
  case error {
    ApiError(msg) -> "ApiError: " <> msg
    RateLimited -> "RateLimited"
    Timeout -> "Timeout"
    InvalidResponse(detail) -> "InvalidResponse: " <> detail
  }
}

/// Format a SessionEndReason for display.
fn format_end_reason(reason: SessionEndReason) -> String {
  case reason {
    NormalEnd -> "normal"
    ErrorEnd(_) -> "error"
    MaxIterationsExceeded(n) -> {
      "max_iterations_exceeded (" <> int.to_string(n) <> " iterations)"
    }
    Interrupted -> "interrupted"
  }
}

// ── Actor Initialization ───────────────────────────────────────────────

/// Start the terminal printer actor.
/// The actor will print formatted SessionEvents to stdout.
pub fn start() -> Result(Subject(SessionEvent), actor.StartError) {
  let builder =
    actor.new(State)
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Handle incoming messages to the printer actor.
fn handle_message(
  state: State,
  event: SessionEvent,
) -> actor.Next(State, SessionEvent) {
  let formatted = format_event(event)
  io.println(formatted)
  actor.continue(state)
}
