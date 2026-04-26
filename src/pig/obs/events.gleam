//// Telemetry event definitions for the pig library.
////
//// A single `Event` union type with typed variants for every pig event.
//// One `emit(Event)` function, one `event_name(Event)` accessor.
////
//// Uses a thin Erlang FFI (`pig_obs_ffi`) that wraps `:telemetry.execute/3`
//// and converts string-keyed dicts to atom-keyed maps.

import gleam/dict.{type Dict}
import gleam/string

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

// ── Event Union Type ─────────────────────────────────────────────────
//// All pig telemetry events as typed variants. Construct these directly
//// and pass to `emit()`.

pub type Event {
  InferenceStart(model: String, message_count: Int)
  InferenceStop(model: String, message_count: Int, duration_ms: Int)
  InferenceException(model: String, message_count: Int)
  ToolStart(tool_name: String, tool_call_id: String)
  ToolStop(tool_name: String, tool_call_id: String, duration_ms: Int)
  ToolException(tool_name: String, tool_call_id: String)
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

/// All pig event names, useful for attaching a listener to everything.
pub fn all_event_names() -> List(List(String)) {
  [
    inference_start_name(),
    inference_stop_name(),
    inference_exception_name(),
    tool_start_name(),
    tool_stop_name(),
    tool_exception_name(),
  ]
}

// ── Event Accessors ──────────────────────────────────────────────────

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

/// Convert an event name list to a dot-separated string for display.
pub fn name_to_string(name: List(String)) -> String {
  string.join(name, ".")
}

// ── Emit ─────────────────────────────────────────────────────────────

/// Emit a typed telemetry event.
pub fn emit(event: Event) -> Nil {
  case event {
    InferenceStart(model:, message_count:) -> {
      let measurements =
        dict.from_list([
          #("system_time", ffi_system_time()),
          #("message_count", message_count),
        ])
      let metadata = dict.from_list([#("model", model)])
      ffi_execute(inference_start_name(), measurements, metadata)
    }
    InferenceStop(model:, message_count:, duration_ms:) -> {
      let measurements =
        dict.from_list([
          #("system_time", ffi_system_time()),
          #("duration", duration_ms),
          #("message_count", message_count),
        ])
      let metadata = dict.from_list([#("model", model)])
      ffi_execute(inference_stop_name(), measurements, metadata)
    }
    InferenceException(model:, message_count:) -> {
      let measurements =
        dict.from_list([
          #("system_time", ffi_system_time()),
          #("message_count", message_count),
        ])
      let metadata = dict.from_list([#("model", model)])
      ffi_execute(inference_exception_name(), measurements, metadata)
    }
    ToolStart(tool_name:, tool_call_id:) -> {
      let measurements = dict.from_list([#("system_time", ffi_system_time())])
      let metadata =
        dict.from_list([
          #("tool_name", tool_name),
          #("tool_call_id", tool_call_id),
        ])
      ffi_execute(tool_start_name(), measurements, metadata)
    }
    ToolStop(tool_name:, tool_call_id:, duration_ms:) -> {
      let measurements =
        dict.from_list([
          #("system_time", ffi_system_time()),
          #("duration", duration_ms),
        ])
      let metadata =
        dict.from_list([
          #("tool_name", tool_name),
          #("tool_call_id", tool_call_id),
        ])
      ffi_execute(tool_stop_name(), measurements, metadata)
    }
    ToolException(tool_name:, tool_call_id:) -> {
      let measurements = dict.from_list([#("system_time", ffi_system_time())])
      let metadata =
        dict.from_list([
          #("tool_name", tool_name),
          #("tool_call_id", tool_call_id),
        ])
      ffi_execute(tool_exception_name(), measurements, metadata)
    }
  }
}

// ── Generic Emit Helpers ─────────────────────────────────────────────
// For custom events outside the built-in set.

/// Emit a custom start event with auto-populated system_time measurement.
pub fn emit_start(
  name: List(String),
  meta: Dict(String, String),
) -> Nil {
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
pub fn emit_exception(
  name: List(String),
  meta: Dict(String, String),
) -> Nil {
  let measurements = dict.from_list([#("system_time", ffi_system_time())])
  ffi_execute(name, measurements, meta)
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
      InferenceStart(model:, message_count: count)
    }
    ["pig", "inference", "stop"] -> {
      let assert Ok(model) = dict.get(raw.metadata, "model")
      let assert Ok(count) = dict.get(raw.measurements, "message_count")
      let assert Ok(dur) = dict.get(raw.measurements, "duration")
      InferenceStop(model:, message_count: count, duration_ms: dur)
    }
    ["pig", "inference", "exception"] -> {
      let assert Ok(model) = dict.get(raw.metadata, "model")
      let assert Ok(count) = dict.get(raw.measurements, "message_count")
      InferenceException(model:, message_count: count)
    }
    ["pig", "tool", "start"] -> {
      let assert Ok(name) = dict.get(raw.metadata, "tool_name")
      let assert Ok(id) = dict.get(raw.metadata, "tool_call_id")
      ToolStart(tool_name: name, tool_call_id: id)
    }
    ["pig", "tool", "stop"] -> {
      let assert Ok(name) = dict.get(raw.metadata, "tool_name")
      let assert Ok(id) = dict.get(raw.metadata, "tool_call_id")
      let assert Ok(dur) = dict.get(raw.measurements, "duration")
      ToolStop(tool_name: name, tool_call_id: id, duration_ms: dur)
    }
    ["pig", "tool", "exception"] -> {
      let assert Ok(name) = dict.get(raw.metadata, "tool_name")
      let assert Ok(id) = dict.get(raw.metadata, "tool_call_id")
      ToolException(tool_name: name, tool_call_id: id)
    }
    _ -> {
      let msg = "unknown telemetry event: " <> name_to_string(raw.name)
      panic as msg
    }
  }
}
