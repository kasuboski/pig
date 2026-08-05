//// Telemetry event definitions for the pig library.
////
//// A single `Event` union type with typed variants for every pig event.
//// One `emit(Event)` function, one `event_name(Event)` accessor.
////
//// Uses a thin Erlang FFI (`pig_obs_ffi`) that wraps `:telemetry.execute/3`
//// and converts string-keyed dicts to atom-keyed maps.
//// All pig telemetry events as typed variants. Construct these directly
//// and pass to `emit()`.

import gleam/dict.{type Dict}
import gleam/option.{type Option, None, Some}
import gleam/string
import pig/provider
import pig_protocol/error.{type AiError}
import pig_protocol/message.{type Message, type ToolCall}
import pig_protocol/stop_reason.{type StopReason}
import pig_protocol/thinking

// ── FFI Bindings ─────────────────────────────────────────────────────

@external(erlang, "pig_obs_ffi", "execute")
fn ffi_execute(
  name: List(String),
  measurements: Dict(String, Int),
  metadata: Dict(String, String),
) -> Nil

@external(erlang, "pig_obs_ffi", "system_time")
fn ffi_system_time() -> Int

/// Get the current monotonic system time. Used for duration measurements.
pub fn system_time() -> Int {
  ffi_system_time()
}

/// Public wrapper for the FFI execute function.
/// This allows other modules (like the dispatcher) to emit telemetry events
/// without exposing the FFI implementation directly.
pub fn execute_telemetry(
  name: List(String),
  measurements: Dict(String, Int),
  metadata: Dict(String, String),
) -> Nil {
  ffi_execute(name, measurements, metadata)
}

// ── Event Union Type ─────────────────────────────────────────────────

pub type Event {
  InferenceStart(
    model: String,
    message_count: Int,
    settings: provider.InferenceSettings,
  )
  InferenceStop(
    model: String,
    message_count: Int,
    duration_ms: Int,
    response_id: Option(String),
    stop_reason: Option(StopReason),
    input_tokens: Option(Int),
    output_tokens: Option(Int),
    settings: provider.InferenceSettings,
  )
  InferenceException(
    model: String,
    message_count: Int,
    error_type: String,
    settings: provider.InferenceSettings,
  )
  ToolStart(tool_name: String, tool_call_id: String, arguments_json: String)
  ToolStop(
    tool_name: String,
    tool_call_id: String,
    duration_ms: Int,
    result: String,
  )
  ToolException(tool_name: String, tool_call_id: String, arguments_json: String)
}

// ── Event Name Constants ─────────────────────────────────────────────

pub fn inference_start_name() -> List(String) {
  ["pig", "inference", "start"]
}

pub fn inference_stop_name() -> List(String) {
  ["pig", "inference", "stop"]
}

pub fn inference_exception_name() -> List(String) {
  ["pig", "inference", "exception"]
}

pub fn tool_start_name() -> List(String) {
  ["pig", "tool", "start"]
}

pub fn tool_stop_name() -> List(String) {
  ["pig", "tool", "stop"]
}

pub fn tool_exception_name() -> List(String) {
  ["pig", "tool", "exception"]
}

pub fn tool_blocked_name() -> List(String) {
  ["pig", "tool", "blocked"]
}

/// All pig event names, useful for attaching a listener to everything.
pub fn all_event_names() -> List(List(String)) {
  [
    inference_start_name(),
    inference_stop_name(),
    inference_exception_name(),
    tool_start_name(),
    tool_stop_name(),
    tool_exception_name(),
    tool_blocked_name(),
  ]
}

/// Get the telemetry event name for a given event.
pub fn event_name(event: Event) -> List(String) {
  case event {
    InferenceStart(..) -> inference_start_name()
    InferenceStop(..) -> inference_stop_name()
    InferenceException(..) -> inference_exception_name()
    ToolStart(..) -> tool_start_name()
    ToolStop(..) -> tool_stop_name()
    ToolException(..) -> tool_exception_name()
  }
}

// ── Event Accessors ──────────────────────────────────────────────────

/// Convert an event name list to a dot-separated string for display.
pub fn name_to_string(name: List(String)) -> String {
  string.join(name, ".")
}

// ── Emit ─────────────────────────────────────────────────────────────

/// Emit a typed telemetry event.
pub fn emit(event: Event) -> Nil {
  case event {
    InferenceStart(model:, message_count:, settings:) -> {
      let measurements =
        dict.from_list([
          #("system_time", ffi_system_time()),
          #("message_count", message_count),
        ])
      let metadata =
        dict.from_list([
          #("model", model),
          #("thinking", settings_to_string(settings)),
        ])
      ffi_execute(inference_start_name(), measurements, metadata)
    }
    InferenceStop(
      model:,
      message_count:,
      duration_ms:,
      response_id:,
      stop_reason:,
      input_tokens:,
      output_tokens:,
      settings:,
    ) -> {
      // Build measurements with optional token counts
      let base_measurements =
        dict.from_list([
          #("system_time", ffi_system_time()),
          #("duration", duration_ms),
          #("message_count", message_count),
        ])
      let measurements =
        base_measurements
        |> maybe_insert_int("input_tokens", input_tokens)
        |> maybe_insert_int("output_tokens", output_tokens)

      // Build metadata with optional string fields
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

      ffi_execute(inference_stop_name(), measurements, metadata)
    }
    InferenceException(model:, message_count:, error_type:, settings:) -> {
      let measurements =
        dict.from_list([
          #("system_time", ffi_system_time()),
          #("message_count", message_count),
        ])
      let metadata =
        dict.from_list([
          #("model", model),
          #("error_type", error_type),
          #("thinking", settings_to_string(settings)),
        ])
      ffi_execute(inference_exception_name(), measurements, metadata)
    }
    ToolStart(tool_name:, tool_call_id:, arguments_json:) -> {
      let measurements = dict.from_list([#("system_time", ffi_system_time())])
      let metadata =
        dict.from_list([
          #("tool_name", tool_name),
          #("tool_call_id", tool_call_id),
          #("arguments_json", arguments_json),
        ])
      ffi_execute(tool_start_name(), measurements, metadata)
    }
    ToolStop(tool_name:, tool_call_id:, duration_ms:, result:) -> {
      let measurements =
        dict.from_list([
          #("system_time", ffi_system_time()),
          #("duration", duration_ms),
        ])
      let metadata =
        dict.from_list([
          #("tool_name", tool_name),
          #("tool_call_id", tool_call_id),
          #("result", result),
        ])
      ffi_execute(tool_stop_name(), measurements, metadata)
    }
    ToolException(tool_name:, tool_call_id:, arguments_json:) -> {
      let measurements = dict.from_list([#("system_time", ffi_system_time())])
      let metadata =
        dict.from_list([
          #("tool_name", tool_name),
          #("tool_call_id", tool_call_id),
          #("arguments_json", arguments_json),
        ])
      ffi_execute(tool_exception_name(), measurements, metadata)
    }
  }
}

// ── Generic Emit Helpers ─────────────────────────────────────────────
// For custom events outside the built-in set.

/// Emit a custom start event with auto-populated system_time measurement.
pub fn emit_start(name: List(String), meta: Dict(String, String)) -> Nil {
  let measurements = dict.from_list([#("system_time", ffi_system_time())])
  ffi_execute(name, measurements, meta)
}

/// Emit a custom stop event with duration and system_time measurements.
pub fn emit_stop(
  name: List(String),
  duration_ms: Int,
  meta: Dict(String, String),
) -> Nil {
  let measurements =
    dict.from_list([
      #("system_time", ffi_system_time()),
      #("duration", duration_ms),
    ])
  ffi_execute(name, measurements, meta)
}

/// Emit a custom exception event with auto-populated system_time measurement.
pub fn emit_exception(name: List(String), meta: Dict(String, String)) -> Nil {
  let measurements = dict.from_list([#("system_time", ffi_system_time())])
  ffi_execute(name, measurements, meta)
}

// ── Optional Field Helpers ───────────────────────────────────────────────
// Helper functions to conditionally insert optional values into dicts.

fn maybe_insert_int(
  dict: Dict(String, Int),
  key: String,
  value: Option(Int),
) -> Dict(String, Int) {
  case value {
    Some(v) -> dict.insert(dict, key, v)
    None -> dict
  }
}

fn maybe_insert_string(
  dict: Dict(String, String),
  key: String,
  value: Option(String),
) -> Dict(String, String) {
  case value {
    Some(v) -> dict.insert(dict, key, v)
    None -> dict
  }
}

fn maybe_get_string(dict: Dict(String, String), key: String) -> Option(String) {
  case dict.get(dict, key) {
    Ok(v) -> Some(v)
    Error(Nil) -> None
  }
}

fn maybe_get_int(dict: Dict(String, Int), key: String) -> Option(Int) {
  case dict.get(dict, key) {
    Ok(v) -> Some(v)
    Error(Nil) -> None
  }
}

/// Convert inference settings to the provider-neutral stable string used by
/// telemetry and session serialization.
pub fn settings_to_string(settings: provider.InferenceSettings) -> String {
  case settings {
    provider.InferenceSettings(thinking: provider.UseProviderDefault) ->
      "provider_default"
    provider.InferenceSettings(thinking: provider.UseThinkingLevel(level)) ->
      thinking.to_string(level)
  }
}

/// Parse the provider-neutral representation of inference settings.
pub fn settings_from_string(
  value: String,
) -> Result(provider.InferenceSettings, Nil) {
  case value {
    "provider_default" -> Ok(provider.default_settings())
    _ ->
      case thinking.from_string(value) {
        Ok(level) -> Ok(provider.with_thinking_level(level))
        Error(Nil) -> Error(Nil)
      }
  }
}

fn settings_from_metadata(
  metadata: Dict(String, String),
) -> provider.InferenceSettings {
  case maybe_get_string(metadata, "thinking") {
    Some(value) -> {
      case settings_from_string(value) {
        Ok(settings) -> settings
        Error(Nil) -> provider.default_settings()
      }
    }
    None -> provider.default_settings()
  }
}

// ── Decoding ─────────────────────────────────────────────────────────
// Reconstruct typed Events from raw captured data (used by the test listener).

/// Internal type for raw captured telemetry data.
pub type RawCapturedEvent {
  RawCapturedEvent(
    name: List(String),
    measurements: Dict(String, Int),
    metadata: Dict(String, String),
  )
}

/// Decode a raw captured event into a typed Event.
/// Panics on unknown event names or missing fields (internal consistency).
pub fn decode(raw: RawCapturedEvent) -> Event {
  case raw.name {
    ["pig", "inference", "start"] -> {
      let assert Ok(model) = dict.get(raw.metadata, "model")
      let assert Ok(count) = dict.get(raw.measurements, "message_count")
      let settings = settings_from_metadata(raw.metadata)
      InferenceStart(model:, message_count: count, settings:)
    }
    ["pig", "inference", "stop"] -> {
      let assert Ok(model) = dict.get(raw.metadata, "model")
      let assert Ok(count) = dict.get(raw.measurements, "message_count")
      let assert Ok(dur) = dict.get(raw.measurements, "duration")
      let response_id = maybe_get_string(raw.metadata, "response_id")
      let raw_stop_reason = maybe_get_string(raw.metadata, "stop_reason")
      let sr = option.map(raw_stop_reason, stop_reason.from_string)
      let input_tokens = maybe_get_int(raw.measurements, "input_tokens")
      let output_tokens = maybe_get_int(raw.measurements, "output_tokens")
      let settings = settings_from_metadata(raw.metadata)
      InferenceStop(
        model:,
        message_count: count,
        duration_ms: dur,
        response_id:,
        stop_reason: sr,
        input_tokens:,
        output_tokens:,
        settings:,
      )
    }
    ["pig", "inference", "exception"] -> {
      let assert Ok(model) = dict.get(raw.metadata, "model")
      let assert Ok(count) = dict.get(raw.measurements, "message_count")
      let assert Ok(error_type) = dict.get(raw.metadata, "error_type")
      let settings = settings_from_metadata(raw.metadata)
      InferenceException(model:, message_count: count, error_type:, settings:)
    }
    ["pig", "tool", "start"] -> {
      let assert Ok(name) = dict.get(raw.metadata, "tool_name")
      let assert Ok(id) = dict.get(raw.metadata, "tool_call_id")
      let assert Ok(args) = dict.get(raw.metadata, "arguments_json")
      ToolStart(tool_name: name, tool_call_id: id, arguments_json: args)
    }
    ["pig", "tool", "stop"] -> {
      let assert Ok(name) = dict.get(raw.metadata, "tool_name")
      let assert Ok(id) = dict.get(raw.metadata, "tool_call_id")
      let assert Ok(dur) = dict.get(raw.measurements, "duration")
      let assert Ok(res) = dict.get(raw.metadata, "result")
      ToolStop(tool_name: name, tool_call_id: id, duration_ms: dur, result: res)
    }
    ["pig", "tool", "exception"] -> {
      let assert Ok(name) = dict.get(raw.metadata, "tool_name")
      let assert Ok(id) = dict.get(raw.metadata, "tool_call_id")
      let assert Ok(args) = dict.get(raw.metadata, "arguments_json")
      ToolException(tool_name: name, tool_call_id: id, arguments_json: args)
    }
    _ -> {
      let msg = "unknown telemetry event: " <> name_to_string(raw.name)
      panic as msg
    }
  }
}

// ── SessionEvent (rich events for pig consumers) ────────────────────
// Carries full message content for session replay and OTel.

/// Reasons why a session ended.
pub type SessionEndReason {
  NormalEnd
  ErrorEnd(AiError)
  MaxIterationsExceeded(Int)
  Interrupted
}

/// Hook points for lifecycle events.
pub type HookPoint {
  BeforeToolCall
  AfterToolCall
  BeforeInference
  AfterInference
  OnError
  OnComplete
  OnSessionStart
  OnSessionShutdown
}

/// Details of a hook's action.
pub type HookActionDetail {
  HookActionDetail(action_type: String, description: String)
}

/// Rich session events for pig consumers (session writer, terminal printer, OTel).
/// Carries full message content, tool args/results, token counts, and timing.
pub type SessionEvent {
  SessionStarted(
    agent_id: Option(String),
    agent_name: Option(String),
    model: String,
    provider_name: Option(String),
    system_prompt: Option(String),
  )
  InferenceStarted(
    model: String,
    message_count: Int,
    settings: provider.InferenceSettings,
  )
  InferenceCompleted(
    message: Message,
    response_id: Option(String),
    response_model: Option(String),
    stop_reason: Option(StopReason),
    input_tokens: Option(Int),
    output_tokens: Option(Int),
    duration_ms: Int,
    input_messages: List(Message),
    settings: provider.InferenceSettings,
  )
  ToolStarted(tool_call: ToolCall)
  ToolExecuted(tool_call: ToolCall, result: String, duration_ms: Int)
  ToolBlocked(tool_call: ToolCall, hook_name: String, reason: String)
  HookActed(hook_name: String, hook_point: HookPoint, action: HookActionDetail)
  InferenceFailed(
    model: String,
    error: AiError,
    duration_ms: Int,
    input_messages: List(Message),
    settings: provider.InferenceSettings,
  )
  InferenceSettingsChanged(settings: provider.InferenceSettings)
  SessionEnded(reason: SessionEndReason)
}
