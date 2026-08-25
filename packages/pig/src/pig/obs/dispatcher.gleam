//// Dispatcher actor for observability events.
////
//// The dispatcher is an OTP actor that:
//// 1. Receives `Event(SessionEvent)` messages
//// 2. Calls `emit_telemetry(event)` — projects lightweight metrics to `:telemetry` (ALWAYS, by construction)
//// 3. Fans out the full event to registered consumers (fire-and-forget `process.send`)
//// 4. Accepts `RegisterConsumer(StartedConsumer)` to dynamically add consumers

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor.{type StartError}
import gleam/otp/supervision
import logging
import pig/obs/consumer_spec
import pig/obs/events.{
  type SessionEvent, HookActed, InferenceCompleted, InferenceFailed,
  InferenceStarted, SessionEnded, SessionStarted, ToolBlocked, ToolExecuted,
  ToolStarted, execute_telemetry, inference_exception_name, inference_start_name,
  inference_stop_name, system_time, tool_blocked_name, tool_start_name,
  tool_stop_name,
}
import pig/provider
import pig_protocol/error.{
  type AiError, ApiError, InvalidResponse, RateLimited, Timeout,
}
import pig_protocol/stop_reason

// ── Public Types ─────────────────────────────────────────────────────

/// Errors returned when registering a dispatcher consumer.
pub type RegistrationError {
  /// The dispatcher did not acknowledge registration before the timeout.
  RegistrationTimeout
}

/// Errors returned when flushing the dispatcher.
pub type FlushError {
  /// The dispatcher did not acknowledge the barrier before the timeout.
  FlushTimeout
}

/// Errors returned when draining consumers through the dispatcher.
pub type ShutdownError {
  /// The dispatcher did not acknowledge the shutdown request before the timeout.
  ShutdownTimeout
  /// A consumer did not acknowledge its graceful stop.
  ConsumerStop(error: consumer_spec.StopError)
}

/// Messages that the dispatcher actor can receive.
pub type DispatcherMessage {
  /// A session event to dispatch to consumers and telemetry.
  Event(SessionEvent)
  /// Register a new consumer to receive session events.
  RegisterConsumer(consumer_spec.StartedConsumer)
  /// Register a consumer and acknowledge it after it is installed.
  RegisterConsumerSync(consumer_spec.StartedConsumer, Subject(Nil))
  /// Acknowledge after all earlier events have been dispatched.
  Flush(reply_to: Subject(Nil))
  /// Drain events and ask every registered consumer to acknowledge shutdown.
  Shutdown(reply_to: Subject(Result(Nil, ShutdownError)))
  /// Stop the dispatcher actor (for testing/cleanup).
  Stop
}

// ── Internal Types ───────────────────────────────────────────────────

/// Internal state for the dispatcher actor.
type State {
  State(
    consumers: List(consumer_spec.StartedConsumer),
    shutdown_requested: Bool,
  )
}

// ── Public API ───────────────────────────────────────────────────────

/// Start a new dispatcher actor.
pub fn start() -> Result(Subject(DispatcherMessage), StartError) {
  let builder =
    actor.new(State(consumers: [], shutdown_requested: False))
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Register a consumer and wait until the dispatcher has installed it.
///
/// The barrier makes it safe to emit an event immediately after registration.
/// Returns a typed error if the dispatcher does not acknowledge registration.
pub fn register_consumer(
  dispatcher: Subject(DispatcherMessage),
  consumer: consumer_spec.StartedConsumer,
) -> Result(Nil, RegistrationError) {
  register_consumer_with_timeout(dispatcher, consumer, 5000)
}

/// Register a consumer with an explicit acknowledgement timeout.
///
/// This is useful for callers that need a bounded startup failure and for
/// deterministic tests; successful registration remains synchronous.
pub fn register_consumer_with_timeout(
  dispatcher: Subject(DispatcherMessage),
  consumer: consumer_spec.StartedConsumer,
  timeout_ms: Int,
) -> Result(Nil, RegistrationError) {
  let reply_subject = process.new_subject()
  process.send(dispatcher, RegisterConsumerSync(consumer, reply_subject))
  case process.receive(reply_subject, timeout_ms) {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> Error(RegistrationTimeout)
  }
}

/// Synchronous alias for `register_consumer`.
pub fn register_consumer_sync(
  dispatcher: Subject(DispatcherMessage),
  consumer: consumer_spec.StartedConsumer,
) -> Result(Nil, RegistrationError) {
  register_consumer(dispatcher, consumer)
}

/// Wait until every event sent before this call has been dispatched.
pub fn flush(dispatcher: Subject(DispatcherMessage)) -> Nil {
  case flush_with_timeout(dispatcher, 5000) {
    Ok(Nil) -> Nil
    Error(FlushTimeout) ->
      logging.log(logging.Warning, "Event dispatcher flush timed out")
  }
}

/// Wait for every event sent before this call to be dispatched.
pub fn flush_with_timeout(
  dispatcher: Subject(DispatcherMessage),
  timeout_ms: Int,
) -> Result(Nil, FlushError) {
  let reply_to = process.new_subject()
  process.send(dispatcher, Flush(reply_to:))
  case process.receive(reply_to, timeout_ms) {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> Error(FlushTimeout)
  }
}

/// Drain the dispatcher and request a graceful stop from every consumer.
///
/// The dispatcher handles this message after all earlier events in its own
/// mailbox. Consumer stop messages are sent by that same process, preserving
/// event-before-stop ordering for each consumer.
pub fn shutdown(
  dispatcher: Subject(DispatcherMessage),
) -> Result(Nil, ShutdownError) {
  shutdown_with_timeout(dispatcher, 5000)
}

/// Drain the dispatcher with an explicit shutdown acknowledgement timeout.
pub fn shutdown_with_timeout(
  dispatcher: Subject(DispatcherMessage),
  timeout_ms: Int,
) -> Result(Nil, ShutdownError) {
  let reply_to = process.new_subject()
  process.send(dispatcher, Shutdown(reply_to:))
  case process.receive(reply_to, timeout_ms) {
    Ok(result) -> result
    Error(Nil) -> Error(ShutdownTimeout)
  }
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
  consumers: List(consumer_spec.StartedConsumer),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let builder =
      actor.new(State(consumers: consumers, shutdown_requested: False))
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
      list.each(state.consumers, fn(consumer) {
        consumer_spec.consume(consumer, event)
      })
      actor.continue(state)
    }
    RegisterConsumer(consumer) -> {
      actor.continue(State(..state, consumers: [consumer, ..state.consumers]))
    }
    RegisterConsumerSync(consumer, reply_subject) -> {
      process.send(reply_subject, Nil)
      actor.continue(State(..state, consumers: [consumer, ..state.consumers]))
    }
    Flush(reply_to) -> {
      process.send(reply_to, Nil)
      actor.continue(state)
    }
    Shutdown(reply_to) -> {
      case state.shutdown_requested {
        True -> {
          process.send(reply_to, Ok(Nil))
          actor.continue(state)
        }
        False -> {
          let result = stop_consumers(state.consumers)
          process.send(reply_to, result)
          actor.continue(State(..state, shutdown_requested: True))
        }
      }
    }
    Stop -> {
      actor.stop()
    }
  }
}

fn stop_consumers(
  consumers: List(consumer_spec.StartedConsumer),
) -> Result(Nil, ShutdownError) {
  list.fold(list.reverse(consumers), Ok(Nil), fn(result, consumer) {
    let stop_result = consumer_spec.stop_with_result(consumer)
    case result, stop_result {
      Ok(Nil), Ok(Nil) -> Ok(Nil)
      Ok(Nil), Error(error) -> Error(ConsumerStop(error))
      Error(previous), Ok(Nil) -> Error(previous)
      Error(previous), Error(_) -> Error(previous)
    }
  })
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
          #("thinking", provider.settings_to_string(settings)),
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
          #("thinking", provider.settings_to_string(settings)),
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
          #("thinking", provider.settings_to_string(settings)),
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
    ToolExecuted(tool_call:, result: _, duration_ms:) -> {
      let measurements =
        dict.from_list([
          #("system_time", system_time()),
          #("duration", duration_ms),
        ])
      let metadata =
        dict.from_list([
          #("tool_name", tool_call.name),
          #("tool_call_id", tool_call.id),
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
    error.Cancelled -> "cancelled"
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
