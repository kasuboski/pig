import pig_protocol/error.{type AiError}

/// A pure, sans-IO description of an HTTP request.
///
/// pig_protocol intentionally does not perform network IO. Callers supply a
/// `Transport` function that turns this description into a response body or
/// an error.
pub type HttpRequest {
  HttpRequest(
    url: String,
    headers: List(#(String, String)),
    body: String,
    timeout_ms: Int,
  )
}

/// A transport function performs the actual network request.
///
/// This is the seam that lets the same protocol package work with `gleam_httpc`,
/// a test stub, or any future backend.
pub type Transport =
  fn(HttpRequest) -> Result(String, AiError)

/// A streaming transport delivers raw byte chunks to a callback as they
/// arrive. SSE framing belongs at the protocol boundary, after this callback.
pub type StreamTransport =
  fn(HttpRequest, fn(BitArray) -> Nil) -> Result(Nil, AiError)
