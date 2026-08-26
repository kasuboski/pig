//// Compatibility-shaped helpers backed by the shared Hackney transport.

import pig_transport
import pig_transport/hackney as shared_hackney

/// The response shape retained by proxy helper callers.
pub type HackneyResponse {
  OkResponse(status: Int, headers: List(#(String, String)), body: BitArray)
  ErrorResponse(reason: String)
}

/// Ensure Hackney is running.
pub fn ensure_started() -> Nil {
  shared_hackney.ensure_started()
}

/// Make a blocking request through the shared adapter.
pub fn sync_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
) -> HackneyResponse {
  case shared_hackney.sync_request(method, url, headers, body, timeout_ms) {
    pig_transport.Response(status:, headers:, body:) ->
      OkResponse(status:, headers:, body:)
    pig_transport.TransportError(reason:) -> ErrorResponse(reason:)
  }
}

/// Return the shared production transport.
pub fn transport() -> pig_transport.Transport {
  shared_hackney.transport()
}
