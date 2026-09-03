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
import pig/obs/consumer_spec
import pig/obs/events.{
  type HookPoint, type SessionEndReason, type SessionEvent, ErrorEnd,
  Interrupted, MaxIterationsExceeded, NormalEnd,
}
import pig/provider
import pig_protocol/error.{
  type AiError, ApiError, Cancelled, InvalidResponse, RateLimited, Timeout,
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
      cached_input_tokens:,
      duration_ms:,
      input_messages: _,
      settings: _,
    ) -> {
      let duration_str = int.to_string(duration_ms) <> "ms"
      let cached_part = case cached_input_tokens {
        Some(cached) -> " (" <> int.to_string(cached) <> " cached)"
        None -> ""
      }
      let token_part = case input_tokens, output_tokens {
        Some(input), Some(output) -> {
          " | tokens: "
          <> int.to_string(input)
          <> "→"
          <> int.to_string(output)
          <> cached_part
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
    Cancelled -> "Cancelled"
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

/// Messages owned by the unsupervised terminal consumer.
type ConsumerMessage {
  Consume(SessionEvent)
  Stop(Subject(Nil))
}

/// Start a terminal consumer and return its owned endpoint.
pub fn start() -> Result(consumer_spec.StartedConsumer, actor.StartError) {
  let builder =
    actor.new(State)
    |> actor.on_message(handle_managed_message)
  case actor.start(builder) {
    Ok(started) -> {
      let subject = started.data
      Ok(
        consumer_spec.started_with_result(
          fn(event) { process.send(subject, Consume(event)) },
          fn() {
            let reply_subject = process.new_subject()
            process.send(subject, Stop(reply_subject))
            case process.receive(reply_subject, 5000) {
              Ok(Nil) -> Ok(Nil)
              Error(Nil) -> Error(consumer_spec.StopTimeout)
            }
          },
        ),
      )
    }
    Error(e) -> Error(e)
  }
}

/// Stop a terminal consumer via its typed `Stop` message.
pub fn stop(consumer: consumer_spec.StartedConsumer) -> Nil {
  consumer_spec.stop(consumer)
}

/// Start a terminal consumer for dispatcher registration.
pub fn start_consumer() -> Result(
  consumer_spec.StartedConsumer,
  actor.StartError,
) {
  start()
}

/// Create a supervised terminal consumer with a graceful drain control.
pub fn supervised(
  name: Name(consumer_spec.SupervisedMessage),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let builder =
      actor.new(State)
      |> actor.on_message(handle_control_message)
      |> actor.named(name)
    case actor.start(builder) {
      Ok(started) -> Ok(actor.Started(data: Nil, pid: started.pid))
      Error(e) -> Error(e)
    }
  })
}

fn handle_control_message(
  state: State,
  message: consumer_spec.SupervisedMessage,
) -> actor.Next(State, consumer_spec.SupervisedMessage) {
  case message {
    consumer_spec.Event(event) -> {
      io.println(format_event(event))
      actor.continue(state)
    }
    consumer_spec.Stop(reply_subject) -> {
      process.send(reply_subject, Nil)
      actor.continue(state)
    }
  }
}

fn handle_managed_message(
  state: State,
  message: ConsumerMessage,
) -> actor.Next(State, ConsumerMessage) {
  case message {
    Consume(event) -> {
      let formatted = format_event(event)
      io.println(formatted)
      actor.continue(state)
    }
    Stop(reply_subject) -> {
      process.send(reply_subject, Nil)
      actor.stop()
    }
  }
}
