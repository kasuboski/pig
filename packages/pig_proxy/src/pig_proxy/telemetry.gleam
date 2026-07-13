//// Proxy telemetry events.
////
//// A single `ProxyEvent` union type with typed variants for every proxy
//// lifecycle event. One `emit(ProxyEvent)` function emits via `:telemetry`.
////
//// The background metrics aggregator attaches as a `:telemetry` handler
//// (see `pig_proxy/metrics.gleam`) to consume these events asynchronously.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string

// ── FFI Bindings ────────────────────────────────────────────────

@external(erlang, "pig_proxy_telemetry_ffi", "ensure_started")
pub fn ensure_started() -> Nil

@external(erlang, "pig_proxy_telemetry_ffi", "execute")
fn ffi_execute(
  name: List(String),
  measurements: Dict(String, Int),
  metadata: Dict(String, String),
) -> Nil

@external(erlang, "pig_proxy_telemetry_ffi", "system_time")
pub fn system_time() -> Int

@external(erlang, "pig_proxy_telemetry_ffi", "attach_forwarder")
fn ffi_attach_forwarder(
  pid: process.Pid,
  event_names: List(List(String)),
) -> HandlerId

@external(erlang, "pig_proxy_telemetry_ffi", "detach_forwarder")
fn ffi_detach_forwarder(handler_id: HandlerId) -> Nil

/// Opaque handler ID returned by `attach_forwarder`.
pub type HandlerId

// ── Event Union Type ────────────────────────────────────────────

/// All proxy telemetry events as typed variants.
pub type ProxyEvent {
  /// A request was received and is about to be forwarded.
  RequestStart(
    target_id: String,
    provider: String,
    model: String,
    streaming: Bool,
  )
  /// A request completed successfully.
  RequestStop(
    target_id: String,
    provider: String,
    model: String,
    status: Int,
    duration_ms: Int,
    input_tokens: Option(Int),
    output_tokens: Option(Int),
  )
  /// A request failed (after exhausting retries).
  RequestError(
    target_id: String,
    provider: String,
    model: String,
    error_type: String,
  )
  /// A streaming chunk was forwarded to the client.
  StreamChunk(
    target_id: String,
    provider: String,
    model: String,
    chunk_bytes: Int,
  )
  /// A circuit breaker changed state.
  CircuitStateChange(
    target_id: String,
    provider: String,
    model: String,
    new_state: String,
  )
}

// ── Event Names ─────────────────────────────────────────────────

pub fn request_start_name() -> List(String) {
  ["pig_proxy", "request", "start"]
}

pub fn request_stop_name() -> List(String) {
  ["pig_proxy", "request", "stop"]
}

pub fn request_error_name() -> List(String) {
  ["pig_proxy", "request", "error"]
}

pub fn stream_chunk_name() -> List(String) {
  ["pig_proxy", "stream", "chunk"]
}

pub fn circuit_state_change_name() -> List(String) {
  ["pig_proxy", "circuit", "state_change"]
}

/// All event names — used to attach the metrics handler.
pub fn all_event_names() -> List(List(String)) {
  [
    request_start_name(),
    request_stop_name(),
    request_error_name(),
    stream_chunk_name(),
    circuit_state_change_name(),
  ]
}

/// Get the telemetry event name for a given event.
pub fn event_name(event: ProxyEvent) -> List(String) {
  case event {
    RequestStart(..) -> request_start_name()
    RequestStop(..) -> request_stop_name()
    RequestError(..) -> request_error_name()
    StreamChunk(..) -> stream_chunk_name()
    CircuitStateChange(..) -> circuit_state_change_name()
  }
}

/// Convert an event name list to a dot-separated string for display.
pub fn name_to_string(name: List(String)) -> String {
  string.join(name, ".")
}

// ── Emit ────────────────────────────────────────────────────────

/// Emit a typed telemetry event.
pub fn emit(event: ProxyEvent) -> Nil {
  case event {
    RequestStart(target_id:, provider:, model:, streaming:) ->
      ffi_execute(
        request_start_name(),
        dict.from_list([#("system_time", system_time())]),
        dict.from_list([
          #("target_id", target_id),
          #("provider", provider),
          #("model", model),
          #("streaming", bool_to_string(streaming)),
        ]),
      )

    RequestStop(
      target_id:,
      provider:,
      model:,
      status:,
      duration_ms:,
      input_tokens:,
      output_tokens:,
    ) ->
      ffi_execute(
        request_stop_name(),
        dict.from_list([
          #("system_time", system_time()),
          #("duration_ms", duration_ms),
          #("status", status),
        ]),
        dict.from_list([
          #("target_id", target_id),
          #("provider", provider),
          #("model", model),
          #("input_tokens", option_to_string(input_tokens)),
          #("output_tokens", option_to_string(output_tokens)),
        ]),
      )

    RequestError(target_id:, provider:, model:, error_type:) ->
      ffi_execute(
        request_error_name(),
        dict.from_list([#("system_time", system_time())]),
        dict.from_list([
          #("target_id", target_id),
          #("provider", provider),
          #("model", model),
          #("error_type", error_type),
        ]),
      )

    StreamChunk(target_id:, provider:, model:, chunk_bytes:) ->
      ffi_execute(
        stream_chunk_name(),
        dict.from_list([
          #("system_time", system_time()),
          #("chunk_bytes", chunk_bytes),
        ]),
        dict.from_list([
          #("target_id", target_id),
          #("provider", provider),
          #("model", model),
        ]),
      )

    CircuitStateChange(target_id:, provider:, model:, new_state:) ->
      ffi_execute(
        circuit_state_change_name(),
        dict.from_list([#("system_time", system_time())]),
        dict.from_list([
          #("target_id", target_id),
          #("provider", provider),
          #("model", model),
          #("new_state", new_state),
        ]),
      )
  }
}

// ── Handler attachment ──────────────────────────────────────────

/// Attach a telemetry handler that forwards events to a process.
/// Returns an opaque handler ID that can be used to detach later.
pub fn attach_forwarder(
  pid: process.Pid,
  event_names: List(List(String)),
) -> HandlerId {
  ffi_attach_forwarder(pid, event_names)
}

/// Detach a previously attached handler.
pub fn detach_forwarder(handler_id: HandlerId) -> Nil {
  ffi_detach_forwarder(handler_id)
}

// ── Helpers ─────────────────────────────────────────────────────

fn bool_to_string(b: Bool) -> String {
  case b {
    True -> "true"
    False -> "false"
  }
}

fn option_to_string(opt: Option(Int)) -> String {
  case opt {
    Some(n) -> int.to_string(n)
    None -> ""
  }
}
