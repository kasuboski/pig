import gleam/dict
import gleam/erlang/process
import gleam/int
import gleeunit
import pig_proxy/metrics
import pig_proxy/telemetry

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Setup ───────────────────────────────────────────────────────

/// Start the metrics actor and return the subject plus a cleanup function
/// that detaches the telemetry handler.
fn setup() -> #(
  process.Subject(metrics.MetricsMsg),
  fn() -> Nil,
) {
  telemetry.ensure_started()
  let assert Ok(#(subject, handler_id)) = metrics.start()
  #(subject, fn() { telemetry.detach_forwarder(handler_id) })
}

/// Send a ProxyMetricsEvent to the actor (async), then synchronize with
/// get_snapshot (sync via actor.call) so the event is processed before
/// we inspect the snapshot.
fn send_event_and_snapshot(
  subject: process.Subject(metrics.MetricsMsg),
  event: metrics.MetricsMsg,
) -> metrics.MetricsSnapshot {
  process.send(subject, event)
  metrics.get_snapshot(subject)
}

fn request_stop_event(
  model: String,
  duration_ms: Int,
  status: Int,
) -> metrics.MetricsMsg {
  metrics.ProxyMetricsEvent(
    name: ["pig_proxy", "request", "stop"],
    measurements: dict.from_list([
      #("system_time", "1000"),
      #("duration_ms", int.to_string(duration_ms)),
      #("status", int.to_string(status)),
    ]),
    metadata: dict.from_list([
      #("target_id", "test"),
      #("model", model),
      #("input_tokens", ""),
      #("output_tokens", ""),
    ]),
  )
}

fn request_error_event(model: String, error_type: String) -> metrics.MetricsMsg {
  metrics.ProxyMetricsEvent(
    name: ["pig_proxy", "request", "error"],
    measurements: dict.from_list([#("system_time", "1000")]),
    metadata: dict.from_list([
      #("target_id", "test"),
      #("model", model),
      #("error_type", error_type),
    ]),
  )
}

fn stream_chunk_event(model: String, chunk_bytes: Int) -> metrics.MetricsMsg {
  metrics.ProxyMetricsEvent(
    name: ["pig_proxy", "stream", "chunk"],
    measurements: dict.from_list([
      #("system_time", "1000"),
      #("chunk_bytes", int.to_string(chunk_bytes)),
    ]),
    metadata: dict.from_list([
      #("target_id", "test"),
      #("model", model),
    ]),
  )
}

// ── Tests ───────────────────────────────────────────────────────

pub fn empty_actor_returns_empty_snapshot_test() {
  let #(subject, cleanup) = setup()
  let snapshot = metrics.get_snapshot(subject)
  assert 0 == dict.size(snapshot.models)
  cleanup()
}

pub fn request_stop_event_increments_request_count_test() {
  let #(subject, cleanup) = setup()
  let snapshot =
    send_event_and_snapshot(subject, request_stop_event("gpt-4", 200, 200))
  let assert Ok(m) = dict.get(snapshot.models, "gpt-4")
  assert m.request_count == 1
  assert m.last_status == 200
  cleanup()
}

pub fn multiple_request_stop_events_calculate_percentiles_test() {
  let #(subject, cleanup) = setup()
  // Send 5 request_stop events with durations: 100, 200, 300, 400, 500
  // sorted: [100, 200, 300, 400, 500]
  // P50: index = 50*5/100 = 2 → 300
  // P95: index = 95*5/100 = 4 → 500
  // P99: index = 99*5/100 = 4 → 500
  let _ = send_event_and_snapshot(subject, request_stop_event("gpt-4", 100, 200))
  let _ = send_event_and_snapshot(subject, request_stop_event("gpt-4", 200, 200))
  let _ = send_event_and_snapshot(subject, request_stop_event("gpt-4", 300, 200))
  let _ = send_event_and_snapshot(subject, request_stop_event("gpt-4", 400, 200))
  let snapshot =
    send_event_and_snapshot(subject, request_stop_event("gpt-4", 500, 200))
  let assert Ok(m) = dict.get(snapshot.models, "gpt-4")
  assert m.request_count == 5
  assert m.latency_p50_ms == 300
  assert m.latency_p95_ms == 500
  assert m.latency_p99_ms == 500
  cleanup()
}

pub fn request_error_event_increments_error_count_test() {
  let #(subject, cleanup) = setup()
  let snapshot =
    send_event_and_snapshot(subject, request_error_event("gpt-4", "timeout"))
  let assert Ok(m) = dict.get(snapshot.models, "gpt-4")
  assert m.error_count == 1
  assert m.request_count == 0
  cleanup()
}

pub fn stream_chunk_event_accumulates_bytes_test() {
  let #(subject, cleanup) = setup()
  let _ = send_event_and_snapshot(subject, stream_chunk_event("gpt-4", 100))
  let snapshot =
    send_event_and_snapshot(subject, stream_chunk_event("gpt-4", 200))
  let assert Ok(m) = dict.get(snapshot.models, "gpt-4")
  assert m.bytes_streamed == 300
  cleanup()
}

pub fn events_for_different_models_create_separate_entries_test() {
  let #(subject, cleanup) = setup()
  let _ =
    send_event_and_snapshot(subject, request_stop_event("gpt-4", 200, 200))
  let snapshot =
    send_event_and_snapshot(subject, request_stop_event("claude-3", 150, 200))
  assert 2 == dict.size(snapshot.models)
  let assert Ok(m1) = dict.get(snapshot.models, "gpt-4")
  assert m1.request_count == 1
  let assert Ok(m2) = dict.get(snapshot.models, "claude-3")
  assert m2.request_count == 1
  cleanup()
}

pub fn request_stop_and_error_events_track_independently_test() {
  let #(subject, cleanup) = setup()
  let _ =
    send_event_and_snapshot(subject, request_stop_event("gpt-4", 200, 200))
  let _ =
    send_event_and_snapshot(subject, request_stop_event("gpt-4", 300, 200))
  let _ =
    send_event_and_snapshot(subject, request_error_event("gpt-4", "timeout"))
  let snapshot = metrics.get_snapshot(subject)
  let assert Ok(m) = dict.get(snapshot.models, "gpt-4")
  assert m.request_count == 2
  assert m.error_count == 1
  cleanup()
}
