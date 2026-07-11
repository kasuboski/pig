import gleam/dict
import gleam/string
import gleeunit
import pig_proxy/metrics.{
  type MetricsSnapshot, MetricSnapshot, MetricsSnapshot,
}
import pig_proxy/metrics_endpoint

pub fn main() -> Nil {
  gleeunit.main()
}

fn sample_snapshot() -> MetricsSnapshot {
  MetricsSnapshot(models: dict.from_list([#(
    "gpt-4",
    MetricSnapshot(
      request_count: 100,
      error_count: 5,
      latency_p50_ms: 200,
      latency_p95_ms: 800,
      latency_p99_ms: 1200,
      bytes_streamed: 1_048_576,
      last_status: 200,
    ),
  )]))
}

fn multi_model_snapshot() -> MetricsSnapshot {
  MetricsSnapshot(models: dict.from_list([
    #(
      "zephyr",
      MetricSnapshot(
        request_count: 10,
        error_count: 1,
        latency_p50_ms: 50,
        latency_p95_ms: 200,
        latency_p99_ms: 300,
        bytes_streamed: 1024,
        last_status: 200,
      ),
    ),
    #(
      "alpha",
      MetricSnapshot(
        request_count: 50,
        error_count: 2,
        latency_p50_ms: 100,
        latency_p95_ms: 400,
        latency_p99_ms: 600,
        bytes_streamed: 8192,
        last_status: 200,
      ),
    ),
  ]))
}

// ── render ──────────────────────────────────────────────────────

pub fn render_empty_snapshot_has_type_lines_test() {
  let output = metrics_endpoint.render(metrics.empty_snapshot())
  assert True == string.contains(output, "# TYPE pig_proxy_requests_total counter")
  assert True == string.contains(output, "# TYPE pig_proxy_errors_total counter")
  assert True == string.contains(output, "# TYPE pig_proxy_latency_p50_ms gauge")
}

pub fn render_includes_model_label_test() {
  let output = metrics_endpoint.render(sample_snapshot())
  assert True == string.contains(output, "model=\"gpt-4\"")
}

pub fn render_includes_request_count_test() {
  let output = metrics_endpoint.render(sample_snapshot())
  assert True == string.contains(
    output,
    "pig_proxy_requests_total{model=\"gpt-4\"} 100",
  )
}

pub fn render_includes_error_count_test() {
  let output = metrics_endpoint.render(sample_snapshot())
  assert True == string.contains(
    output,
    "pig_proxy_errors_total{model=\"gpt-4\"} 5",
  )
}

pub fn render_includes_latency_p50_test() {
  let output = metrics_endpoint.render(sample_snapshot())
  assert True == string.contains(
    output,
    "pig_proxy_latency_p50_ms{model=\"gpt-4\"} 200",
  )
}

pub fn render_includes_latency_p95_test() {
  let output = metrics_endpoint.render(sample_snapshot())
  assert True == string.contains(
    output,
    "pig_proxy_latency_p95_ms{model=\"gpt-4\"} 800",
  )
}

pub fn render_includes_latency_p99_test() {
  let output = metrics_endpoint.render(sample_snapshot())
  assert True == string.contains(
    output,
    "pig_proxy_latency_p99_ms{model=\"gpt-4\"} 1200",
  )
}

pub fn render_includes_bytes_streamed_test() {
  let output = metrics_endpoint.render(sample_snapshot())
  assert True == string.contains(
    output,
    "pig_proxy_bytes_streamed_total{model=\"gpt-4\"} 1048576",
  )
}

pub fn render_multiple_models_sorted_alphabetically_test() {
  let output = metrics_endpoint.render(multi_model_snapshot())
  // "alpha" should appear before "zephyr": split on "zephyr" and check
  // that "alpha" is in the part before it.
  let assert [before_zephyr, ..] = string.split(output, "zephyr")
  assert True == string.contains(before_zephyr, "alpha")
}

pub fn render_ends_with_newline_test() {
  let output = metrics_endpoint.render(sample_snapshot())
  assert True == string.ends_with(output, "\n")
}
