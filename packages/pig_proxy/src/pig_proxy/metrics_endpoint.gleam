//// Prometheus metrics endpoint.
////
//// Renders a `MetricsSnapshot` as Prometheus text exposition format
//// suitable for scraping by Prometheus/Grafana.

import gleam/bytes_tree
import gleam/dict
import gleam/http/response
import gleam/int
import gleam/list
import gleam/string
import mist
import pig_proxy/metrics.{
  type MetricSnapshot, MetricSnapshot, type MetricsSnapshot,
}
import pig_proxy/model_catalog.{type Catalog}
import gleam/float
import gleam/option.{None, Some}

/// Render a metrics snapshot as Prometheus text.
///
/// Emits counter, gauge, and histogram-style lines with per-model labels:
///
///   - `pig_proxy_requests_total` (counter)
///   - `pig_proxy_errors_total` (counter)
///   - `pig_proxy_latency_p50_ms` (gauge)
///   - `pig_proxy_latency_p95_ms` (gauge)
///   - `pig_proxy_latency_p99_ms` (gauge)
///   - `pig_proxy_bytes_streamed_total` (counter)
///   - `pig_proxy_input_tokens_total` (counter)
///   - `pig_proxy_output_tokens_total` (counter)
///   - `pig_proxy_cost_usd_total` (counter)
pub fn render(snapshot: MetricsSnapshot, catalog: Catalog) -> String {
  let lines = [
    "# TYPE pig_proxy_requests_total counter",
    "# TYPE pig_proxy_errors_total counter",
    "# TYPE pig_proxy_latency_p50_ms gauge",
    "# TYPE pig_proxy_latency_p95_ms gauge",
    "# TYPE pig_proxy_latency_p99_ms gauge",
    "# TYPE pig_proxy_bytes_streamed_total counter",
    "# TYPE pig_proxy_input_tokens_total counter",
    "# TYPE pig_proxy_output_tokens_total counter",
    "# TYPE pig_proxy_cost_usd_total counter",
  ]

  let model_lines =
    snapshot.models
    |> dict.to_list
    |> list.sort(by: fn(a, b) { string.compare(a.0, b.0) })
    |> list.flat_map(fn(entry: #(String, MetricSnapshot)) {
      let #(
        model,
        MetricSnapshot(
          request_count:,
          error_count:,
          latency_p50_ms:,
          latency_p95_ms:,
          latency_p99_ms:,
          bytes_streamed:,
          input_tokens:,
          output_tokens:,
          last_status: _,
        ),
      ) = entry
      let label = "model=\"" <> escape_prometheus_label(model) <> "\""
      let cost = case model_catalog.find(catalog, model) {
        Some(info) -> model_catalog.cost_usd(info, input_tokens, output_tokens)
        None -> 0.0
      }
      [
        "pig_proxy_requests_total{" <> label <> "} " <> int.to_string(
          request_count,
        ),
        "pig_proxy_errors_total{" <> label <> "} " <> int.to_string(
          error_count,
        ),
        "pig_proxy_latency_p50_ms{" <> label <> "} " <> int.to_string(
          latency_p50_ms,
        ),
        "pig_proxy_latency_p95_ms{" <> label <> "} " <> int.to_string(
          latency_p95_ms,
        ),
        "pig_proxy_latency_p99_ms{" <> label <> "} " <> int.to_string(
          latency_p99_ms,
        ),
        "pig_proxy_bytes_streamed_total{" <> label <> "} " <> int.to_string(
          bytes_streamed,
        ),
        "pig_proxy_input_tokens_total{" <> label <> "} " <> int.to_string(
          input_tokens,
        ),
        "pig_proxy_output_tokens_total{" <> label <> "} " <> int.to_string(
          output_tokens,
        ),
        "pig_proxy_cost_usd_total{" <> label <> "} " <> float_to_string(cost),
      ]
    })

  string.join(list.append(lines, model_lines), "\n") <> "\n"
}

/// Format a float for Prometheus text with a fixed six decimal places.
fn float_to_string(value: Float) -> String {
  let whole = float.truncate(value)
  let fraction = float.truncate({ value -. int.to_float(whole) } *. 1_000_000.0)
  int.to_string(whole) <> "." <> pad_fraction(fraction)
}

fn pad_fraction(value: Int) -> String {
  let s = int.to_string(value)
  case string.length(s) {
    1 -> "00000" <> s
    2 -> "0000" <> s
    3 -> "000" <> s
    4 -> "00" <> s
    5 -> "0" <> s
    _ -> s
  }
}

/// Escape a string for safe interpolation into a Prometheus label value.
/// Prometheus requires escaping of backslashes, double quotes, and newlines.
fn escape_prometheus_label(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
}

/// Build a mist HTTP response for the `/metrics` endpoint.
pub fn response(
  snapshot: MetricsSnapshot,
  catalog: Catalog,
) -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/plain; version=0.0.4")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(render(snapshot, catalog))))
}
