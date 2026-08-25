//// Hackney adapter for the shared transport.

import gleam/erlang/process
import pig_transport

@external(erlang, "pig_transport_hackney_ffi", "ensure_started")
pub fn ensure_started() -> Nil

@external(erlang, "pig_transport_hackney_ffi", "sync_request")
fn ffi_sync_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
) -> pig_transport.Response

@external(erlang, "pig_transport_hackney_ffi", "stream_connect")
fn ffi_stream_connect(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
  source: process.Subject(pig_transport.SourceEvent),
) -> Nil

/// Make a blocking Hackney request and return its complete response.
pub fn sync_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
) -> pig_transport.Response {
  ensure_started()
  ffi_sync_request(method, url, headers, body, timeout_ms)
}

/// Run the Hackney streaming source for the transport relay.
pub fn stream(
  request: pig_transport.Request,
  source: process.Subject(pig_transport.SourceEvent),
) -> Nil {
  ensure_started()
  ffi_stream_connect(
    request.method,
    request.url,
    request.headers,
    request.body,
    request.timeout_ms,
    source,
  )
}

/// The production Hackney transport.
pub fn transport() -> pig_transport.Transport {
  pig_transport.Transport(
    sync: fn(request) {
      sync_request(
        request.method,
        request.url,
        request.headers,
        request.body,
        request.timeout_ms,
      )
    },
    stream: fn(request, source) { stream(request, source) },
  )
}
