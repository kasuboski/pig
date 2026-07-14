//// Proxy telemetry events.
////
//// A single `ProxyEvent` union type with typed variants for every proxy
//// lifecycle event.
////
//// `emit(ProxyEvent)` has two audiences:
////   - INTERNAL typed consumers (the metrics aggregator): registered via
////     `attach_typed`, called synchronously in the emitting process with
////     the typed event. No string encoding crosses this path.
////   - EXTERNAL consumers (OTel, dashboards): the event is encoded to the
////     BEAM `:telemetry` registry at the edge, after typed fanout.
////
//// Keeping the typed/external split here means the metrics aggregator
//// pattern-matches typed events directly — no string round-trip, and
//// absent token usage stays `None` instead of being flattened to "0".

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// ── FFI Bindings ────────────────────────────────────────────────

@external(erlang, "pig_proxy_telemetry_ffi", "ensure_started")
fn ffi_ensure_started() -> Nil

@external(erlang, "pig_proxy_telemetry_ffi", "execute")
fn ffi_execute(
  name: List(String),
  measurements: Dict(String, Int),
  metadata: Dict(String, String),
) -> Nil

@external(erlang, "pig_proxy_telemetry_ffi", "system_time")
pub fn system_time() -> Int

@external(erlang, "pig_proxy_telemetry_ffi", "handlers_init")
fn handlers_init() -> Nil

@external(erlang, "pig_proxy_telemetry_ffi", "handlers_add")
fn handlers_add(handler: fn(ProxyEvent) -> Nil) -> HandlerId

@external(erlang, "pig_proxy_telemetry_ffi", "handlers_remove")
fn handlers_remove(id: HandlerId) -> Nil

@external(erlang, "pig_proxy_telemetry_ffi", "handlers_get")
fn handlers_get() -> List(#(HandlerId, fn(ProxyEvent) -> Nil))

/// Opaque handler ID returned by `attach_typed`.
pub type HandlerId

// ── Event Union Type ────────────────────────────────────────────

/// All proxy telemetry events as typed variants.
pub type ProxyEvent {
  /// A request was received. Attributed to the request, not a target —
  /// with fallback the serving target is not known until the commit point,
  /// so the terminal `RequestStop`/`RequestError` carry target attribution.
  RequestStart(model: String, streaming: Bool)
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

/// All pig_proxy telemetry event names — useful for external consumers
/// that want to attach to the full set via the BEAM :telemetry registry.
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
///
/// Internal typed handlers registered via `attach_typed` are called
/// synchronously with the typed event (the metrics aggregator consumes
/// here). The event is then encoded and emitted to the BEAM :telemetry
/// registry for external consumers.
pub fn emit(event: ProxyEvent) -> Nil {
  list.each(handlers_get(), fn(entry) {
    let #(_, handler) = entry
    handler(event)
  })
  emit_external(event)
}

/// Encode the typed event to measurements/metadata and emit it to the
/// BEAM :telemetry registry for external consumers. This is the only
/// place the typed → string encoding happens (the edge).
fn emit_external(event: ProxyEvent) -> Nil {
  case event {
    RequestStart(model:, streaming:) ->
      ffi_execute(
        request_start_name(),
        dict.from_list([#("system_time", system_time())]),
        dict.from_list([
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

/// Start the telemetry application and initialise the typed-handler
/// registry. Idempotent.
pub fn ensure_started() -> Nil {
  ffi_ensure_started()
  handlers_init()
}

/// Register a typed handler invoked synchronously by `emit` for every
/// `ProxyEvent`. Returns an opaque ID for `detach_typed`.
pub fn attach_typed(handler: fn(ProxyEvent) -> Nil) -> HandlerId {
  handlers_add(handler)
}

/// Remove a previously registered typed handler.
pub fn detach_typed(id: HandlerId) -> Nil {
  handlers_remove(id)
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
