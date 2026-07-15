import gleam/dict
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleeunit
import pig_proxy/metrics
import pig_proxy/telemetry

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Setup ───────────────────────────────────────────────────────

/// Start the metrics actor and return the subject plus a cleanup function
/// that detaches the typed telemetry handler.
fn setup() -> #(
  process.Subject(metrics.MetricsMsg),
  fn() -> Nil,
) {
  telemetry.ensure_started()
  let assert Ok(#(subject, handler_id)) = metrics.start()
  #(subject, fn() { telemetry.detach_typed(handler_id) })
}

/// Send a typed event to the actor (async), then synchronize with
/// get_snapshot (sync via actor.call) so the event is processed before
/// we inspect the snapshot.
fn send_event_and_snapshot(
  subject: process.Subject(metrics.MetricsMsg),
  event: metrics.MetricsMsg,
) -> metrics.MetricsSnapshot {
  process.send(subject, event)
  metrics.get_snapshot(subject)
}

fn request_stop_event(model: String, duration_ms: Int, status: Int) -> metrics.MetricsMsg {
  request_stop_event_with_tokens(model, duration_ms, status, Some(0), Some(0))
}

fn request_stop_event_with_tokens(
  model: String,
  duration_ms: Int,
  status: Int,
  input_tokens: Option(Int),
  output_tokens: Option(Int),
) -> metrics.MetricsMsg {
  metrics.ProxyEvent(event: telemetry.RequestStop(
    target_id: "test",
    provider: "",
    model:,
    status:,
    duration_ms:,
    input_tokens:,
    output_tokens:,
  ))
}

fn request_error_event(model: String, error_type: String) -> metrics.MetricsMsg {
  metrics.ProxyEvent(event: telemetry.RequestError(
    target_id: "test",
    provider: "",
    model:,
    error_type:,
  ))
}

fn stream_chunk_event(model: String, chunk_bytes: Int) -> metrics.MetricsMsg {
  metrics.ProxyEvent(event: telemetry.StreamChunk(
    target_id: "test",
    provider: "",
    model:,
    chunk_bytes:,
  ))
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

pub fn request_stop_event_accumulates_tokens_test() {
  let #(subject, cleanup) = setup()
  let _ =
    send_event_and_snapshot(subject, request_stop_event_with_tokens(
      "gpt-4", 200, 200, Some(10), Some(20),
    ))
  let snapshot =
    send_event_and_snapshot(subject, request_stop_event_with_tokens(
      "gpt-4", 200, 200, Some(5), Some(7),
    ))
  let assert Ok(m) = dict.get(snapshot.models, "gpt-4")
  assert m.input_tokens == 15
  assert m.output_tokens == 27
  cleanup()
}

/// Absent token usage must not increase previously accumulated totals.
pub fn absent_token_usage_does_not_change_totals_test() {
  let #(subject, cleanup) = setup()
  let _ =
    send_event_and_snapshot(subject, request_stop_event_with_tokens(
      "gpt-4", 200, 200, Some(3), Some(4),
    ))
  let snapshot =
    send_event_and_snapshot(subject, request_stop_event_with_tokens(
      "gpt-4", 200, 200, None, None,
    ))
  let assert Ok(m) = dict.get(snapshot.models, "gpt-4")
  assert m.input_tokens == 3
  assert m.output_tokens == 4
  assert m.request_count == 2
  cleanup()
}

/// A failing typed handler does not prevent later handlers from receiving an
/// event through the protected telemetry callback boundary.
pub fn failing_typed_handler_does_not_stop_fanout_test() {
  telemetry.ensure_started()
  let subject = process.new_subject()
  let failing = telemetry.attach_typed(fn(_) { panic as "expected failure" })
  let succeeding = telemetry.attach_typed(fn(event) {
    process.send(subject, event)
  })

  telemetry.emit(telemetry.RequestStart(model: "gpt-4", streaming: False))
  let assert Ok(telemetry.RequestStart(model: "gpt-4", streaming: False)) =
    process.receive(subject, 1_000)
  telemetry.detach_typed(failing)
  telemetry.detach_typed(succeeding)
}

/// A non-empty provider keys the model as `provider/model`.
pub fn provider_qualifies_the_metrics_key_test() {
  let #(subject, cleanup) = setup()
  let _ =
    send_event_and_snapshot(subject, metrics.ProxyEvent(event: telemetry.RequestStop(
      target_id: "test",
      provider: "openai",
      model: "gpt-4",
      status: 200,
      duration_ms: 50,
      input_tokens: Some(0),
      output_tokens: Some(0),
    )))
  let snapshot = metrics.get_snapshot(subject)
  let assert Ok(m) = dict.get(snapshot.models, "openai/gpt-4")
  assert m.request_count == 1
  cleanup()
}
