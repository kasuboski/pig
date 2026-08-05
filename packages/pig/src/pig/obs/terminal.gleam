//// Terminal pretty printer for SessionEvents.
////
//// OTP actor that receives SessionEvents and prints formatted output.
//// Pure `format_event` function for testing without side effects.

import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import pig/obs/events.{
  type HookPoint, type SessionEndReason, type SessionEvent, ErrorEnd,
  Interrupted, MaxIterationsExceeded, NormalEnd,
}
import pig/provider
import pig_protocol/error.{
  type AiError, ApiError, InvalidResponse, RateLimited, Timeout,
}
import pig_protocol/stop_reason

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

    events.InferenceStarted(model:, message_count:, settings:) -> {
      "[INF] Started | model: "
      <> model
      <> " | messages: "
      <> int.to_string(message_count)
      <> " | thinking: "
      <> provider.settings_to_string(settings)
    }

    events.InferenceCompleted(
      message: _,
      response_id: _,
      response_model: _,
      stop_reason:,
      input_tokens:,
      output_tokens:,
      duration_ms:,
      input_messages: _,
      settings: _,
    ) -> {
      let duration_str = int.to_string(duration_ms) <> "ms"
      let token_part = case input_tokens, output_tokens {
        Some(input), Some(output) -> {
          " | tokens: " <> int.to_string(input) <> "→" <> int.to_string(output)
        }
        _, _ -> ""
      }
      let finish_part = case stop_reason {
        Some(reason) -> " | finish: " <> stop_reason.to_string(reason)
        None -> ""
      }
      "[INF] Completed | " <> duration_str <> token_part <> finish_part
    }

    events.ToolStarted(tool_call:) -> {
      "[TOOL] Started | " <> tool_call.name
    }

    events.ToolExecuted(tool_call:, result: _, duration_ms:) -> {
      let duration_str = int.to_string(duration_ms) <> "ms"
      "[TOOL] " <> tool_call.name <> " | " <> duration_str
    }

    events.ToolBlocked(tool_call:, hook_name:, reason:) -> {
      "[TOOL] Blocked | "
      <> tool_call.name
      <> " | "
      <> hook_name
      <> " | "
      <> reason
    }

    events.HookActed(hook_name:, hook_point:, action:) -> {
      "[HOOK] "
      <> hook_name
      <> " | "
      <> hook_to_string(hook_point)
      <> " | "
      <> action.action_type
    }

    events.InferenceFailed(
      model: _,
      error:,
      duration_ms:,
      input_messages: _,
      settings: _,
    ) -> {
      let duration_str = int.to_string(duration_ms) <> "ms"
      let error_str = format_error(error)
      "[ERR] Inference failed | " <> duration_str <> " | " <> error_str
    }

    events.InferenceSettingsChanged(settings:) ->
      "[SETTINGS] Thinking changed | " <> provider.settings_to_string(settings)

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

/// Format a HookPoint for display.
fn hook_to_string(hook: HookPoint) -> String {
  case hook {
    events.OnSessionStart -> "on_session_start"
    events.OnSessionShutdown -> "on_session_shutdown"
    events.BeforeInference -> "before_inference"
    events.AfterInference -> "after_inference"
    events.BeforeToolCall -> "before_tool_call"
    events.AfterToolCall -> "after_tool_call"
    events.OnError -> "on_error"
    events.OnComplete -> "on_complete"
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

/// Start a terminal consumer actor that accepts SessionEvent directly.
/// Used by the dispatcher to fan out events. Returns the Subject for registration.
/// This is the consumer version of the actor — same as start() since terminal
/// already receives SessionEvent directly.
pub fn start_consumer() -> Result(Subject(SessionEvent), actor.StartError) {
  start()
}

/// Create a supervised terminal consumer actor for use in a supervision tree.
/// The supervised actor's message type is SessionEvent.
pub fn supervised(
  name: Name(SessionEvent),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let builder =
      actor.new(State)
      |> actor.on_message(handle_message)
      |> actor.named(name)
    case actor.start(builder) {
      Ok(started) -> Ok(actor.Started(data: Nil, pid: started.pid))
      Error(e) -> Error(e)
    }
  })
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
