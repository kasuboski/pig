//// Gleam wrapper around the hackney HTTP client FFI.
////
//// Two modes:
////   - `sync_request`: blocking, returns the full response (non-streaming).
////   - `stream`: opens a streaming request, returns synchronously at the
////     first byte (the commit point), then forwards the rest once started.

import gleam/erlang/process
import pig_proxy/transport

/// Result of a synchronous hackney request.
pub type HackneyResponse {
  OkResponse(status: Int, headers: List(#(String, String)), body: BitArray)
  ErrorResponse(reason: String)
}

/// How long to wait for the upstream head (status + first byte) before
/// declaring a streaming attempt a transport failure.
const head_timeout_ms = 30_000

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

@external(erlang, "pig_proxy_hackney_ffi", "stream_connect")
fn ffi_stream_connect(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  head: process.Subject(transport.StreamHead),
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

/// Open a streaming request. A relay process connects to the upstream and
/// reports the head (status + first byte) to a fresh subject; this returns
/// synchronously with that head — the commit point. For a committed
/// attempt the relay then waits to be `StartRelay`-ed by the consumer
/// before forwarding the body.
pub fn stream(req: transport.TransportRequest) -> transport.StreamHead {
  ensure_started()
  let head = process.new_subject()
  let relay = process.spawn(fn() {
    ffi_stream_connect(req.method, req.url, req.headers, req.body, head)
  })
  case process.receive(head, head_timeout_ms) {
    Ok(h) -> h
    Error(Nil) -> {
      process.kill(relay)
      transport.StreamFailure("timeout waiting for upstream head")
    }
  }
}

/// The production transport adapter: wraps `sync_request` and `stream` in
/// the `transport.Transport` port so request execution can talk to
/// upstream without knowing about hackney.
pub fn transport() -> transport.Transport {
  transport.Transport(
    sync: fn(req) {
      case
        sync_request(req.method, req.url, req.headers, req.body, req.timeout_ms)
      {
        OkResponse(status:, headers:, body:) ->
          transport.Response(status:, headers:, body:)
        ErrorResponse(reason:) -> transport.TransportError(reason:)
      }
    },
    stream: fn(req) { stream(req) },
  )
}
