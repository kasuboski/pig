//// Background metrics aggregator actor.
////
//// Attaches as a `:telemetry` handler to proxy events and maintains
//// per-model accumulators for request counts, error rates, latency
//// percentiles (P50/P95/P99), and streaming byte throughput.
////
//// The `/metrics` endpoint (see `pig_proxy/metrics_endpoint.gleam`)
//// queries this actor for a snapshot and renders it as Prometheus text.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/actor
import pig_proxy/telemetry

/// A per-model metric snapshot for Prometheus rendering.
pub type MetricSnapshot {
  MetricSnapshot(
    request_count: Int,
    error_count: Int,
    latency_p50_ms: Int,
    latency_p95_ms: Int,
    latency_p99_ms: Int,
    bytes_streamed: Int,
    input_tokens: Int,
    output_tokens: Int,
    last_status: Int,
  )
}

/// A full snapshot of all model metrics.
pub type MetricsSnapshot {
  MetricsSnapshot(models: Dict(String, MetricSnapshot))
}

/// Messages accepted by the metrics actor.
pub type MetricsMsg {
  /// Forwarded telemetry event from the FFI handler.
  ProxyMetricsEvent(
    name: List(String),
    measurements: Dict(String, String),
    metadata: Dict(String, String),
  )
  /// Request a snapshot of all model metrics.
  GetSnapshot(reply_to: process.Subject(MetricsSnapshot))
}

type ModelMetrics {
  ModelMetrics(
    request_count: Int,
    error_count: Int,
    latency_samples: List(Int),
    bytes_streamed: Int,
    input_tokens: Int,
    output_tokens: Int,
    last_status: Int,
  )
}

type MetricsState {
  MetricsState(models: Dict(String, ModelMetrics))
}

const snapshot_timeout_ms = 5_000

/// Maximum number of latency samples retained per model.
/// Prevents unbounded memory growth in long-running proxies.
const max_latency_samples = 1_000

/// Cap the latency samples list to `max_latency_samples` by keeping
/// the most recent entries (prepended) and dropping the oldest.
fn cap_samples(samples: List(Int)) -> List(Int) {
  case list.length(samples) > max_latency_samples {
    True -> list.take(samples, max_latency_samples)
    False -> samples
  }
}

fn fresh_model_metrics() -> ModelMetrics {
  ModelMetrics(
    request_count: 0,
    error_count: 0,
    latency_samples: [],
    bytes_streamed: 0,
    input_tokens: 0,
    output_tokens: 0,
    last_status: 0,
  )
}

fn handle_message(state: MetricsState, msg: MetricsMsg) {
  case msg {
    ProxyMetricsEvent(name:, measurements:, metadata:) ->
      actor.continue(process_event(state, name, measurements, metadata))

    GetSnapshot(reply_to) -> {
      let snapshot = MetricsSnapshot(
        models: dict.map_values(state.models, fn(_, m) { to_snapshot(m) }),
      )
      process.send(reply_to, snapshot)
      actor.continue(state)
    }
  }
}

fn process_event(
  state: MetricsState,
  name: List(String),
  measurements: Dict(String, String),
  metadata: Dict(String, String),
) -> MetricsState {
  let model = metrics_key(metadata)

  case name {
    ["pig_proxy", "request", "stop"] -> {
      let duration = parse_int(measurements, "duration_ms")
      let status = parse_int(measurements, "status")
      let input_tokens = parse_int(metadata, "input_tokens")
      let output_tokens = parse_int(metadata, "output_tokens")
      let updated = update_model(state.models, model, fn(m) {
        ModelMetrics(
          request_count: m.request_count + 1,
          error_count: m.error_count,
          latency_samples: cap_samples([duration, ..m.latency_samples]),
          bytes_streamed: m.bytes_streamed,
          input_tokens: m.input_tokens + input_tokens,
          output_tokens: m.output_tokens + output_tokens,
          last_status: status,
        )
      })
      MetricsState(models: updated)
    }

    ["pig_proxy", "request", "error"] -> {
      let updated = update_model(state.models, model, fn(model_metrics) {
        ModelMetrics(
          request_count: model_metrics.request_count,
          error_count: model_metrics.error_count + 1,
          latency_samples: model_metrics.latency_samples,
          bytes_streamed: model_metrics.bytes_streamed,
          input_tokens: model_metrics.input_tokens,
          output_tokens: model_metrics.output_tokens,
          last_status: model_metrics.last_status,
        )
      })
      MetricsState(models: updated)
    }

    ["pig_proxy", "stream", "chunk"] -> {
      let chunk_bytes = parse_int(measurements, "chunk_bytes")
      let updated = update_model(state.models, model, fn(model_metrics) {
        ModelMetrics(
          request_count: model_metrics.request_count,
          error_count: model_metrics.error_count,
          latency_samples: model_metrics.latency_samples,
          bytes_streamed: model_metrics.bytes_streamed + chunk_bytes,
          input_tokens: model_metrics.input_tokens,
          output_tokens: model_metrics.output_tokens,
          last_status: model_metrics.last_status,
        )
      })
      MetricsState(models: updated)
    }

    _ -> state
  }
}

fn update_model(
  models: Dict(String, ModelMetrics),
  model: String,
  updater: fn(ModelMetrics) -> ModelMetrics,
) -> Dict(String, ModelMetrics) {
  let current = case dict.get(models, model) {
    Ok(m) -> m
    Error(_) -> fresh_model_metrics()
  }
  dict.insert(models, model, updater(current))
}

fn to_snapshot(m: ModelMetrics) -> MetricSnapshot {
  MetricSnapshot(
    request_count: m.request_count,
    error_count: m.error_count,
    latency_p50_ms: percentile(m.latency_samples, 50),
    latency_p95_ms: percentile(m.latency_samples, 95),
    latency_p99_ms: percentile(m.latency_samples, 99),
    bytes_streamed: m.bytes_streamed,
    input_tokens: m.input_tokens,
    output_tokens: m.output_tokens,
    last_status: m.last_status,
  )
}

/// Calculate the p-th percentile from a list of latency samples.
/// Pure function — sorts the list and picks the nearest-rank index.
pub fn percentile(samples: List(Int), p: Int) -> Int {
  let sorted = list.sort(samples, by: int.compare)
  let n = list.length(sorted)
  case n {
    0 -> 0
    _ -> {
      let index = { p * n } / 100
      let safe_index = case index >= n {
        True -> n - 1
        False -> index
      }
      case nth(sorted, safe_index) {
        Ok(v) -> v
        Error(_) -> 0
      }
    }
  }
}

/// Get the element at a zero-based index. Returns Error(Nil) if out of bounds.
fn nth(list: List(a), index: Int) -> Result(a, Nil) {
  case list, index {
    [], _ -> Error(Nil)
    [first, ..], 0 -> Ok(first)
    [_, ..rest], n -> nth(rest, n - 1)
  }
}

fn parse_int(values: Dict(String, String), key: String) -> Int {
  case dict.get(values, key) {
    Ok(val) -> case int.parse(val) {
      Ok(n) -> n
      Error(_) -> 0
    }
    Error(_) -> 0
  }
}

/// Start the metrics aggregator actor and attach a telemetry handler
/// that forwards events to it.
///
/// Returns the actor subject (for snapshot queries) and a handler ID
/// (for cleanup on shutdown).
pub fn start() -> Result(
  #(process.Subject(MetricsMsg), telemetry.HandlerId),
  actor.StartError,
) {
  let result =
    MetricsState(models: dict.new())
    |> actor.new
    |> actor.on_message(handle_message)
    |> actor.start
  case result {
    Ok(started) -> {
      let handler_id = telemetry.attach_forwarder(
        started.pid,
        telemetry.all_event_names(),
      )
      Ok(#(started.data, handler_id))
    }
    Error(e) -> Error(e)
  }
}

/// Synchronously request a metrics snapshot from the aggregator.
pub fn get_snapshot(
  metrics: process.Subject(MetricsMsg),
) -> MetricsSnapshot {
  actor.call(metrics, waiting: snapshot_timeout_ms, sending: fn(reply_to) {
    GetSnapshot(reply_to)
  })
}

/// Create an empty snapshot (for testing or when no aggregator is running).
pub fn empty_snapshot() -> MetricsSnapshot {
  MetricsSnapshot(models: dict.new())
}

/// Build the metrics dict key from telemetry metadata.
///
/// When `provider` is present and non-empty, the key is
/// `provider/model` (e.g. `"openai/gpt-4o"`) so it matches the
/// models.dev catalog slug. Otherwise the bare model name is used.
fn metrics_key(metadata: Dict(String, String)) -> String {
  let model = case dict.get(metadata, "model") {
    Ok(m) -> m
    Error(_) -> "unknown"
  }
  case dict.get(metadata, "provider") {
    Ok(p) if p != "" -> p <> "/" <> model
    _ -> model
  }
}
