//// Background metrics aggregator actor.
////
//// Consumes typed `ProxyEvent`s (registered as a typed telemetry handler
//// via `telemetry.attach_typed`) and maintains per-model accumulators for
//// request counts, error rates, latency percentiles (P50/P95/P99), token
//// usage, and streaming byte throughput.
////
//// Because events arrive typed, there is no string parsing and no
//// absent-vs-zero conflation: an `input_tokens` of `None` adds nothing,
//// distinguishable from an explicit `0`. The `/metrics` endpoint (see
//// `pig_proxy/metrics_endpoint.gleam`) queries this actor for a snapshot
//// and renders it as Prometheus text.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option
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
    cached_input_tokens: Int,
    last_status: Int,
  )
}

/// A full snapshot of all model metrics.
pub type MetricsSnapshot {
  MetricsSnapshot(models: Dict(String, MetricSnapshot))
}

/// Messages accepted by the metrics actor.
pub type MetricsMsg {
  /// A typed telemetry event forwarded from `telemetry.emit`.
  ProxyEvent(event: telemetry.ProxyEvent)
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
    cached_input_tokens: Int,
    last_status: Int,
  )
}

type MetricsState {
  MetricsState(models: Dict(String, ModelMetrics))
}

const snapshot_timeout_ms = 5000

/// Maximum number of latency samples retained per model.
/// Prevents unbounded memory growth in long-running proxies.
const max_latency_samples = 1000

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
    cached_input_tokens: 0,
    last_status: 0,
  )
}

fn handle_message(state: MetricsState, msg: MetricsMsg) {
  case msg {
    ProxyEvent(event:) -> actor.continue(process_event(state, event))
    GetSnapshot(reply_to) -> {
      let snapshot =
        MetricsSnapshot(
          models: dict.map_values(state.models, fn(_, m) { to_snapshot(m) }),
        )
      process.send(reply_to, snapshot)
      actor.continue(state)
    }
  }
}

/// Apply one typed event to the metrics state.
fn process_event(
  state: MetricsState,
  event: telemetry.ProxyEvent,
) -> MetricsState {
  case event {
    telemetry.RequestStop(
      provider:,
      model:,
      status:,
      duration_ms:,
      input_tokens:,
      output_tokens:,
      cached_input_tokens:,
      ..,
    ) -> {
      let updated =
        update_model(state.models, key(provider, model), fn(m) {
          ModelMetrics(
            request_count: m.request_count + 1,
            error_count: m.error_count,
            latency_samples: cap_samples([duration_ms, ..m.latency_samples]),
            bytes_streamed: m.bytes_streamed,
            input_tokens: m.input_tokens + option.unwrap(input_tokens, 0),
            output_tokens: m.output_tokens + option.unwrap(output_tokens, 0),
            cached_input_tokens: m.cached_input_tokens
              + option.unwrap(cached_input_tokens, 0),
            last_status: status,
          )
        })
      MetricsState(models: updated)
    }

    telemetry.RequestError(provider:, model:, ..) -> {
      let updated =
        update_model(state.models, key(provider, model), fn(m) {
          ModelMetrics(..m, error_count: m.error_count + 1)
        })
      MetricsState(models: updated)
    }

    telemetry.StreamChunk(provider:, model:, chunk_bytes:, ..) -> {
      let updated =
        update_model(state.models, key(provider, model), fn(m) {
          ModelMetrics(..m, bytes_streamed: m.bytes_streamed + chunk_bytes)
        })
      MetricsState(models: updated)
    }

    // RequestStart and CircuitStateChange are not aggregated here.
    telemetry.RequestStart(..) -> state
    telemetry.CircuitStateChange(..) -> state
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
    cached_input_tokens: m.cached_input_tokens,
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

/// Start the metrics aggregator actor and attach a typed telemetry handler
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
      let subject = started.data
      let handler_id =
        telemetry.attach_typed(fn(event) {
          process.send(subject, ProxyEvent(event:))
        })
      Ok(#(subject, handler_id))
    }
    Error(e) -> Error(e)
  }
}

/// Start the metrics actor registered under `name`. Telemetry forwarding is
/// attached separately with `attach_named` so one handler follows the named
/// actor across its supervised restarts.
pub fn start_named(
  name: process.Name(MetricsMsg),
) -> Result(actor.Started(process.Subject(MetricsMsg)), actor.StartError) {
  MetricsState(models: dict.new())
  |> actor.new
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

/// Attach one telemetry forwarder that resolves the currently registered
/// metrics actor on every event. This makes the forwarder restart-stable.
pub fn attach_named(name: process.Name(MetricsMsg)) -> telemetry.HandlerId {
  telemetry.attach_typed(fn(event) {
    case process.named(name) {
      Ok(_) -> process.send(process.named_subject(name), ProxyEvent(event:))
      Error(_) -> Nil
    }
  })
}

/// Synchronously request a metrics snapshot from the aggregator.
pub fn get_snapshot(metrics: process.Subject(MetricsMsg)) -> MetricsSnapshot {
  actor.call(metrics, waiting: snapshot_timeout_ms, sending: fn(reply_to) {
    GetSnapshot(reply_to)
  })
}

/// Create an empty snapshot (for testing or when no aggregator is running).
pub fn empty_snapshot() -> MetricsSnapshot {
  MetricsSnapshot(models: dict.new())
}

/// Build the metrics dict key from a typed event's provider + model.
///
/// When `provider` is present and non-empty, the key is
/// `provider/model` (e.g. `"openai/gpt-4o"`) so it matches the
/// models.dev catalog slug. Otherwise the bare model name is used.
fn key(provider, model) -> String {
  case provider {
    "" -> model
    p -> p <> "/" <> model
  }
}
