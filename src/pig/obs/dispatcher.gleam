//// Dispatcher actor for observability events.
////
//// The dispatcher is an OTP actor that:
//// 1. Receives `Event(SessionEvent)` messages
//// 2. Calls `emit_telemetry(event)` — projects lightweight metrics to `:telemetry` (ALWAYS, by construction)
//// 3. Fans out the full event to registered consumers (fire-and-forget `process.send`)
//// 4. Accepts `RegisterConsumer(Subject(SessionEvent))` to dynamically add consumers

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor.{type StartError}
import gleam/otp/supervision
import pig/ai/error.{type AiError, ApiError, RateLimited, Timeout, InvalidResponse}
import pig/obs/events.{
  type SessionEvent,
  SessionStarted,
  InferenceStarted,
  InferenceCompleted,
  ToolStarted,
  ToolExecuted,
  ToolBlocked,
  ExtensionActed,
  InferenceFailed,
  SessionEnded,
  inference_start_name,
  inference_stop_name,
  inference_exception_name,
  tool_start_name,
  tool_stop_name,
  tool_blocked_name,
  execute_telemetry,
  system_time,
}

// ── Public Types ─────────────────────────────────────────────────────

/// Messages that the dispatcher actor can receive.
pub type DispatcherMessage {
  /// A session event to dispatch to consumers and telemetry.
  Event(SessionEvent)
  /// Register a new consumer to receive session events.
  RegisterConsumer(Subject(SessionEvent))
  /// Stop the dispatcher actor (for testing/cleanup).
  Stop
}

// ── Internal Types ───────────────────────────────────────────────────

/// Internal state for the dispatcher actor.
type State {
  State(consumers: List(Subject(SessionEvent)))
}

// ── Public API ───────────────────────────────────────────────────────

/// Start a new dispatcher actor.
pub fn start() -> Result(Subject(DispatcherMessage), StartError) {
  let builder =
    actor.new(State(consumers: []))
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Create a supervised dispatcher actor for use in a supervision tree.
pub fn supervised(
  name: process.Name(DispatcherMessage),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let builder =
      actor.new(State(consumers: []))
      |> actor.on_message(handle_message)
      |> actor.named(name)
    case actor.start(builder) {
      Ok(started) -> Ok(actor.Started(data: Nil, pid: started.pid))
      Error(e) -> Error(e)
    }
  })
}

// ── Actor Implementation ─────────────────────────────────────────────

/// Handle incoming messages to the dispatcher actor.
fn handle_message(state: State, msg: DispatcherMessage) {
  case msg {
    Event(event) -> {
      emit_telemetry(event) // Always emit telemetry
      // Fan out to all registered consumers
      list.each(state.consumers, fn(consumer) {
        process.send(consumer, event)
      })
      actor.continue(state)
    }
    RegisterConsumer(subject) -> {
      actor.continue(State(consumers: [subject, ..state.consumers]))
    }
    Stop -> {
      actor.stop()
    }
  }
}

// ── Telemetry Emission ───────────────────────────────────────────────

/// Emit telemetry for a session event.
/// This is an internal function that projects lightweight metrics to :telemetry.
/// Only certain events are projected; others (like SessionStarted) are not.
fn emit_telemetry(event: SessionEvent) {
  case event {
    InferenceStarted(model:, message_count:) -> {
      let measurements =
        dict.from_list([
          #("system_time", system_time()),
          #("message_count", message_count),
        ])
      let metadata = dict.from_list([#("model", model)])
      execute_telemetry(inference_start_name(), measurements, metadata)
    }
    InferenceCompleted(
      message: _,
      response_id:,
      response_model:,
      finish_reason:,
      input_tokens:,
      output_tokens:,
      duration_ms:,
      input_messages:,
    ) -> {
      // Build measurements with optional token counts
      let base_measurements =
        dict.from_list([
          #("system_time", system_time()),
          #("duration", duration_ms),
          #("message_count", list.length(input_messages)),
        ])
      let measurements =
        base_measurements
        |> maybe_insert_int("input_tokens", input_tokens)
        |> maybe_insert_int("output_tokens", output_tokens)

      // Build metadata with optional string fields
      // Use response_model if available, otherwise use a placeholder
      let model =
        case response_model {
          Some(m) -> m
          None -> "unknown"
        }
      let base_metadata = dict.from_list([#("model", model)])
      let metadata =
        base_metadata
        |> maybe_insert_string("response_id", response_id)
        |> maybe_insert_string("finish_reason", finish_reason)

      execute_telemetry(inference_stop_name(), measurements, metadata)
    }
    InferenceFailed(error:, duration_ms:, input_messages:) -> {
      let error_type = error_type_to_string(error)
      let measurements =
        dict.from_list([
          #("system_time", system_time()),
          #("message_count", list.length(input_messages)),
          #("duration", duration_ms),
        ])
      let metadata =
        dict.from_list([#("model", "unknown"), #("error_type", error_type)])
      execute_telemetry(inference_exception_name(), measurements, metadata)
    }
    ToolStarted(tool_call:) -> {
      let measurements = dict.from_list([#("system_time", system_time())])
      let metadata =
        dict.from_list([
          #("tool_name", tool_call.name),
          #("tool_call_id", tool_call.id),
          #("arguments_json", tool_call.arguments_json),
        ])
      execute_telemetry(tool_start_name(), measurements, metadata)
    }
    ToolExecuted(tool_call:, result:, duration_ms:) -> {
      let measurements =
        dict.from_list([
          #("system_time", system_time()),
          #("duration", duration_ms),
        ])
      let metadata =
        dict.from_list([
          #("tool_name", tool_call.name),
          #("tool_call_id", tool_call.id),
          #("result", result),
        ])
      execute_telemetry(tool_stop_name(), measurements, metadata)
    }
    ToolBlocked(tool_call:, extension_name:, reason:) -> {
      let measurements = dict.from_list([#("system_time", system_time())])
      let metadata =
        dict.from_list([
          #("tool_name", tool_call.name),
          #("tool_call_id", tool_call.id),
          #("extension_name", extension_name),
          #("reason", reason),
        ])
      execute_telemetry(tool_blocked_name(), measurements, metadata)
    }
    // These events are NOT projected to telemetry
    SessionStarted(..) -> Nil
    ExtensionActed(..) -> Nil
    SessionEnded(..) -> Nil
  }
}

// ── Helper Functions ─────────────────────────────────────────────────

/// Convert an AiError to a string for telemetry metadata.
fn error_type_to_string(error: AiError) -> String {
  case error {
    ApiError(..) -> "api_error"
    RateLimited -> "rate_limited"
    Timeout -> "timeout"
    InvalidResponse(..) -> "invalid_response"
  }
}

/// Helper to conditionally insert an optional integer into a dict.
fn maybe_insert_int(
  dict: Dict(String, Int),
  key: String,
  value: option.Option(Int),
) -> Dict(String, Int) {
  case value {
    Some(v) -> dict.insert(dict, key, v)
    None -> dict
  }
}

/// Helper to conditionally insert an optional string into a dict.
fn maybe_insert_string(
  dict: Dict(String, String),
  key: String,
  value: option.Option(String),
) -> Dict(String, String) {
  case value {
    Some(v) -> dict.insert(dict, key, v)
    None -> dict
  }
}
