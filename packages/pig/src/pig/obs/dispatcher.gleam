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
import pig/obs/events.{
  type SessionEvent, HookActed, InferenceCompleted, InferenceFailed,
  InferenceStarted, SessionEnded, SessionStarted, ToolBlocked, ToolExecuted,
  ToolStarted, execute_telemetry, inference_exception_name, inference_start_name,
  inference_stop_name, settings_to_string, system_time, tool_blocked_name,
  tool_start_name, tool_stop_name,
}
import pig_protocol/error.{
  type AiError, ApiError, InvalidResponse, RateLimited, Timeout,
}
import pig_protocol/stop_reason

// ── Public Types ─────────────────────────────────────────────────────

/// Messages that the dispatcher actor can receive.
pub type DispatcherMessage {
  /// A session event to dispatch to consumers and telemetry.
  Event(SessionEvent)
  /// Register a new consumer to receive session events.
  RegisterConsumer(Subject(SessionEvent))
  /// Register a consumer and acknowledge it after it is installed.
  RegisterConsumerSync(Subject(SessionEvent), Subject(Nil))
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

/// Register a consumer and wait until the dispatcher has installed it.
///
/// The barrier makes it safe to emit an event immediately after registration.
/// The asynchronous `RegisterConsumer` message remains available for startup
/// paths that do not need this guarantee.
pub fn register_consumer(
  dispatcher: Subject(DispatcherMessage),
  consumer: Subject(SessionEvent),
) -> Nil {
  let reply_subject = process.new_subject()
  process.send(dispatcher, RegisterConsumerSync(consumer, reply_subject))
  let assert Ok(Nil) = process.receive(reply_subject, 5000)
  Nil
}

/// Synchronous alias for `register_consumer`.
pub fn register_consumer_sync(
  dispatcher: Subject(DispatcherMessage),
  consumer: Subject(SessionEvent),
) -> Nil {
  register_consumer(dispatcher, consumer)
}

/// Create a supervised dispatcher actor for use in a supervision tree.
pub fn supervised(
  name: process.Name(DispatcherMessage),
) -> supervision.ChildSpecification(Nil) {
  supervised_with_consumers(name, [])
}

/// Create a supervised dispatcher with its named consumers configured at start.
///
/// The subjects are retained by every dispatcher reconstruction, so a
/// OneForAll restart cannot lose the consumer registrations.
pub fn supervised_with_consumers(
  name: process.Name(DispatcherMessage),
  consumers: List(Subject(SessionEvent)),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let builder =
      actor.new(State(consumers: consumers))
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
      emit_telemetry(event)
      // Always emit telemetry
      // Fan out to all registered consumers
      list.each(state.consumers, fn(consumer) { process.send(consumer, event) })
      actor.continue(state)
    }
    RegisterConsumer(subject) -> {
      actor.continue(State(consumers: [subject, ..state.consumers]))
    }
    RegisterConsumerSync(subject, reply_subject) -> {
      process.send(reply_subject, Nil)
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
    InferenceStarted(model:, message_count:, settings:) -> {
      let measurements =
        dict.from_list([
          #("system_time", system_time()),
          #("message_count", message_count),
        ])
      let metadata =
        dict.from_list([
          #("model", model),
          #("thinking", settings_to_string(settings)),
        ])
      execute_telemetry(inference_start_name(), measurements, metadata)
    }
    InferenceCompleted(
      message: _,
      response_id:,
      response_model:,
      stop_reason:,
      input_tokens:,
      output_tokens:,
      duration_ms:,
      input_messages:,
      settings:,
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
      let model = case response_model {
        Some(m) -> m
        None -> "unknown"
      }
      let base_metadata =
        dict.from_list([
          #("model", model),
          #("thinking", settings_to_string(settings)),
        ])
      let metadata =
        base_metadata
        |> maybe_insert_string("response_id", response_id)
        |> maybe_insert_string(
          "stop_reason",
          option.map(stop_reason, stop_reason.to_string),
        )

      execute_telemetry(inference_stop_name(), measurements, metadata)
    }
    InferenceFailed(model:, error:, duration_ms:, input_messages:, settings:) -> {
      let error_type = error_type_to_string(error)
      let measurements =
        dict.from_list([
          #("system_time", system_time()),
          #("message_count", list.length(input_messages)),
          #("duration", duration_ms),
        ])
      let metadata =
        dict.from_list([
          #("model", model),
          #("error_type", error_type),
          #("thinking", settings_to_string(settings)),
        ])
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
    ToolBlocked(tool_call:, hook_name:, reason:) -> {
      let measurements = dict.from_list([#("system_time", system_time())])
      let metadata =
        dict.from_list([
          #("tool_name", tool_call.name),
          #("tool_call_id", tool_call.id),
          #("hook_name", hook_name),
          #("reason", reason),
        ])
      execute_telemetry(tool_blocked_name(), measurements, metadata)
    }
    // These events are NOT projected to telemetry
    SessionStarted(..) -> Nil
    HookActed(..) -> Nil
    events.InferenceSettingsChanged(..) -> Nil
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
