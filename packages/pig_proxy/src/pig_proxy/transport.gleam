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
//// Both shapes cross this port:
////   - `sync`: returns the whole buffered response.
////   - `stream`: returns synchronously at the first byte, so the commit
////     point is a value the caller decides on, not a race in a relay loop.

import gleam/erlang/process

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

/// Control message sent to a committed stream relay to start forwarding.
/// The relay owns the `Subject(RelayControl)` it reported in
/// `StreamCommitted`; the consumer (the mist chunked loop) sends
/// `StartRelay` with its own subject once it is ready to receive chunks.
pub type RelayControl {
  StartRelay(forward: process.Subject(StreamRelayMsg))
}

/// Chunks and terminal signals delivered by a committed stream relay to
/// the forward subject named in `StartRelay`. `RelayDone`/`RelayError`
/// are terminal — the relay exits after sending one.
pub type StreamRelayMsg {
  RelayChunk(data: BitArray)
  RelayDone
  RelayError(reason: String)
}

/// The head of a streaming attempt, returned synchronously by `stream`.
/// The commit point lives here: `StreamCommitted` flips the request to
/// committed (the first byte is in hand); the other two variants are
/// pre-commit and the caller may retry or fall back.
///
/// On `StreamCommitted`, the relay has confirmed a 2xx head and received
/// the first body byte. It is paused, holding that byte, waiting for the
/// consumer to send `StartRelay(forward)` to `run`. Once started, it
/// forwards every byte (including the held first one) as `RelayChunk`
/// values, then `RelayDone` or `RelayError`.
pub type StreamHead {
  StreamCommitted(
    status: Int,
    headers: List(#(String, String)),
    run: process.Subject(RelayControl),
  )
  /// Non-2xx head; the full body has been read. NOT committed.
  StreamRejected(
    status: Int,
    headers: List(#(String, String)),
    body: BitArray,
  )
  /// Network-level failure before any head. NOT committed.
  StreamFailure(reason: String)
}

/// The transport port. Implemented by the production hackney adapter and
/// the in-memory test adapter.
pub type Transport {
  Transport(
    sync: fn(TransportRequest) -> TransportResponse,
    stream: fn(TransportRequest) -> StreamHead,
  )
}

/// Perform one synchronous upstream attempt through a transport.
pub fn sync(transport: Transport, req: TransportRequest) -> TransportResponse {
  transport.sync(req)
}

/// Open a streaming upstream attempt through a transport. Returns
/// synchronously with the head decision (the commit point); for a
/// committed attempt the relay then forwards via `StartRelay`.
pub fn stream(transport: Transport, req: TransportRequest) -> StreamHead {
  transport.stream(req)
}
