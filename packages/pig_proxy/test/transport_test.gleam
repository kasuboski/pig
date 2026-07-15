//// Transport adapter tests.

import gleam/bit_array
import gleeunit
import pig_proxy/hackney
import pig_proxy/transport
import support/in_memory_transport

/// Run the transport test suite.
pub fn main() -> Nil {
  gleeunit.main()
}

// ── Production adapter shape ────────────────────────────────────

/// The production Hackney adapter satisfies the transport port shape.
pub fn hackney_transport_returns_a_transport_test() {
  // The production adapter satisfies the port. (Not driven against the
  // network here — that belongs in integration tests.)
  let _ = hackney.transport()
  Nil
}

// ── In-memory adapter ───────────────────────────────────────────

/// Scripted in-memory responses are served in call order.
pub fn in_memory_serves_queue_in_call_order_test() {
  let assert Ok(subject) =
    in_memory_transport.start(
      [
        transport.Response(500, [], <<>>),
        transport.Response(200, [], <<"ok">>),
      ],
      transport.TransportError("exhausted"),
    )
  let t = in_memory_transport.transport(subject)
  let assert transport.Response(500, ..) = transport.sync(
    t,
    transport.TransportRequest("POST", "http://x", [], "", 1000),
  )
  let assert transport.Response(200, ..) = transport.sync(
    t,
    transport.TransportRequest("POST", "http://x", [], "", 1000),
  )
}

/// The in-memory adapter returns its exhaustion response after its queue.
pub fn in_memory_returns_exhausted_when_queue_runs_out_test() {
  let assert Ok(subject) =
    in_memory_transport.start(
      [transport.Response(200, [], <<>>)],
      transport.TransportError("exhausted"),
    )
  let t = in_memory_transport.transport(subject)
  let _ = transport.sync(
    t,
    transport.TransportRequest("POST", "http://x", [], "", 1000),
  )
  let assert transport.TransportError("exhausted") = transport.sync(
    t,
    transport.TransportRequest("POST", "http://x", [], "", 1000),
  )
}

/// The in-memory adapter preserves response headers and bodies.
pub fn in_memory_carries_body_and_headers_test() {
  let assert Ok(subject) =
    in_memory_transport.start(
      [
        transport.Response(
          200,
          [#("content-type", "application/json")],
          bit_array.from_string("{\"hi\":true}"),
        ),
      ],
      transport.TransportError("exhausted"),
    )
  let t = in_memory_transport.transport(subject)
  let assert transport.Response(status:, headers:, body:) = transport.sync(
    t,
    transport.TransportRequest("POST", "http://x", [], "", 1000),
  )
  assert status == 200
  assert headers == [#("content-type", "application/json")]
  assert body == bit_array.from_string("{\"hi\":true}")
}
