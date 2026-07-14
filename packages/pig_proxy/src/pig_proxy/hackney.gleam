//// Gleam wrapper around the hackney HTTP client FFI.
////
//// Two modes:
////   - `sync_request`: blocking, returns the full response (non-streaming).
////   - `stream_request`: async, invokes callbacks for each SSE chunk.

import gleam/erlang/process
import pig_proxy/transport

/// Result of a synchronous hackney request.
pub type HackneyResponse {
  OkResponse(status: Int, headers: List(#(String, String)), body: BitArray)
  ErrorResponse(reason: String)
}

@external(erlang, "pig_proxy_hackney_ffi", "ensure_started")
pub fn ensure_started() -> Nil

@external(erlang, "pig_proxy_hackney_ffi", "sync_request")
fn ffi_sync_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
) -> HackneyResponse

@external(erlang, "pig_proxy_hackney_ffi", "stream_request_loop")
fn ffi_stream_request_loop(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  chunk_cb: fn(BitArray) -> Nil,
  done_cb: fn(Nil) -> Nil,
  error_cb: fn(String) -> Nil,
) -> Nil

/// Make a blocking HTTP request and return the full response.
pub fn sync_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
) -> HackneyResponse {
  ensure_started()
  ffi_sync_request(method, url, headers, body, timeout_ms)
}

/// Start a streaming request in a dedicated relay process.
///
/// The relay receives upstream SSE chunks and invokes:
///   - `on_chunk` for each binary chunk,
///   - `on_done` when the stream completes,
///   - `on_error` if the upstream fails.
///
/// Returns the relay's PID so the caller can monitor or link it.
pub fn stream_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  on_chunk: fn(BitArray) -> Nil,
  on_done: fn(Nil) -> Nil,
  on_error: fn(String) -> Nil,
) -> process.Pid {
  ensure_started()
  process.spawn(fn() {
    ffi_stream_request_loop(method, url, headers, body, on_chunk, on_done, on_error)
  })
}

/// The production transport adapter: wraps `sync_request` in the
/// `transport.Transport` port so request execution can talk to upstream
/// without knowing about hackney. Maps the hackney response into a
/// `transport.Response` (any status) or `transport.TransportError`.
pub fn transport() -> transport.Transport {
  transport.Transport(sync: fn(req) {
    case
      sync_request(req.method, req.url, req.headers, req.body, req.timeout_ms)
    {
      OkResponse(status:, headers:, body:) ->
        transport.Response(status:, headers:, body:)
      ErrorResponse(reason:) -> transport.TransportError(reason:)
    }
  })
}
