//// The upstream transport port.
////
//// The seam across which request execution talks to a "remote but owned"
//// upstream HTTP endpoint. Two adapters implement it — a production
//// hackney adapter (`pig_proxy/hackney.transport`) and an in-memory test
//// adapter — so the seam is real, not hypothetical.
////
//// Retry, fallback, circuit-breaker, commit-point, and telemetry logic
//// live above this port, never inside an adapter. The adapter owns HTTP
//// mechanics and reports outcomes; execution owns policy.
////
//// Only synchronous execution crosses this port today. A streaming
//// variant (returning synchronously at the first byte so the commit point
//// is a value, not a race) is added alongside the streaming execution path.

/// A single upstream attempt.
pub type TransportRequest {
  TransportRequest(
    method: String,
    url: String,
    headers: List(#(String, String)),
    body: String,
    timeout_ms: Int,
  )
}

/// The outcome of one synchronous upstream attempt, returned before any
/// retry/fallback decision. A `Response` carries any status (the caller
/// classifies retryability from `status`); a `TransportError` means no
/// response was obtained (network error, timeout).
pub type TransportResponse {
  Response(
    status: Int,
    headers: List(#(String, String)),
    body: BitArray,
  )
  TransportError(reason: String)
}

/// The transport port. Implemented by the production hackney adapter and
/// the in-memory test adapter.
pub type Transport {
  Transport(sync: fn(TransportRequest) -> TransportResponse)
}

/// Perform one synchronous upstream attempt through a transport.
pub fn sync(transport: Transport, req: TransportRequest) -> TransportResponse {
  transport.sync(req)
}
