import gleam/dict
import gleam/float
import gleam/int
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleeunit
import pig_proxy/metrics.{type MetricsSnapshot, MetricSnapshot, MetricsSnapshot}
import pig_proxy/metrics_endpoint
import pig_proxy/model_catalog

pub fn main() -> Nil {
  gleeunit.main()
}

fn sample_snapshot() -> MetricsSnapshot {
  MetricsSnapshot(
    models: dict.from_list([
      #(
        "gpt-4",
        MetricSnapshot(
          request_count: 100,
          error_count: 5,
          latency_p50_ms: 200,
          latency_p95_ms: 800,
          latency_p99_ms: 1200,
          bytes_streamed: 1_048_576,
          input_tokens: 1000,
          output_tokens: 500,
          cached_input_tokens: 800,
          last_status: 200,
        ),
      ),
    ]),
  )
}

fn multi_model_snapshot() -> MetricsSnapshot {
  MetricsSnapshot(
    models: dict.from_list([
      #(
        "zephyr",
        MetricSnapshot(
          request_count: 10,
          error_count: 1,
          latency_p50_ms: 50,
          latency_p95_ms: 200,
          latency_p99_ms: 300,
          bytes_streamed: 1024,
          input_tokens: 0,
          output_tokens: 0,
          cached_input_tokens: 0,
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
          input_tokens: 0,
          output_tokens: 0,
          cached_input_tokens: 0,
          last_status: 200,
        ),
      ),
    ]),
  )
}

fn empty_catalog() -> model_catalog.Catalog {
  model_catalog.empty()
}

// ── render ──────────────────────────────────────────────────────

pub fn render_empty_snapshot_has_type_lines_test() {
  let output =
    metrics_endpoint.render(metrics.empty_snapshot(), empty_catalog())
  assert string.contains(output, "# TYPE pig_proxy_requests_total counter")
  assert string.contains(output, "# TYPE pig_proxy_errors_total counter")
  assert string.contains(output, "# TYPE pig_proxy_latency_p50_ms gauge")
}

pub fn render_includes_model_label_test() {
  let output = metrics_endpoint.render(sample_snapshot(), empty_catalog())
  assert string.contains(output, "model=\"gpt-4\"")
}

pub fn render_includes_request_count_test() {
  let output = metrics_endpoint.render(sample_snapshot(), empty_catalog())
  assert string.contains(
    output,
    "pig_proxy_requests_total{model=\"gpt-4\"} 100",
  )
}

pub fn render_includes_error_count_test() {
  let output = metrics_endpoint.render(sample_snapshot(), empty_catalog())
  assert string.contains(output, "pig_proxy_errors_total{model=\"gpt-4\"} 5")
}

pub fn render_includes_latency_p50_test() {
  let output = metrics_endpoint.render(sample_snapshot(), empty_catalog())
  assert string.contains(
    output,
    "pig_proxy_latency_p50_ms{model=\"gpt-4\"} 200",
  )
}

pub fn render_includes_latency_p95_test() {
  let output = metrics_endpoint.render(sample_snapshot(), empty_catalog())
  assert string.contains(
    output,
    "pig_proxy_latency_p95_ms{model=\"gpt-4\"} 800",
  )
}

pub fn render_includes_latency_p99_test() {
  let output = metrics_endpoint.render(sample_snapshot(), empty_catalog())
  assert string.contains(
    output,
    "pig_proxy_latency_p99_ms{model=\"gpt-4\"} 1200",
  )
}

pub fn render_includes_bytes_streamed_test() {
  let output = metrics_endpoint.render(sample_snapshot(), empty_catalog())
  assert string.contains(
    output,
    "pig_proxy_bytes_streamed_total{model=\"gpt-4\"} 1048576",
  )
}

pub fn render_includes_token_and_cost_series_test() {
  let output = metrics_endpoint.render(sample_snapshot(), empty_catalog())
  assert string.contains(
    output,
    "pig_proxy_input_tokens_total{model=\"gpt-4\"} 1000",
  )
  assert string.contains(
    output,
    "pig_proxy_output_tokens_total{model=\"gpt-4\"} 500",
  )
  assert string.contains(
    output,
    "pig_proxy_cached_input_tokens_total{model=\"gpt-4\"} 800",
  )
  assert string.contains(output, "pig_proxy_cost_usd{model=\"gpt-4\"} 0.000000")
}

pub fn render_multiple_models_sorted_alphabetically_test() {
  let output = metrics_endpoint.render(multi_model_snapshot(), empty_catalog())
  // "alpha" should appear before "zephyr": split on "zephyr" and check
  // that "alpha" is in the part before it.
  let assert [before_zephyr, ..] = string.split(output, "zephyr")
  assert string.contains(before_zephyr, "alpha")
}

pub fn render_ends_with_newline_test() {
  let output = metrics_endpoint.render(sample_snapshot(), empty_catalog())
  assert string.ends_with(output, "\n")
}

pub fn render_cost_matches_catalog_cost_usd_test() {
  let catalog_json =
    "{\"openai\":{\"id\":\"openai\",\"models\":{\"gpt-4\":{\"id\":\"gpt-4\",\"cost\":{\"input\":5,\"output\":15},\"limit\":{\"context\":128000,\"output\":16384}}}}}"
  let assert Ok(catalog) = model_catalog.parse(catalog_json)
  let snapshot = sample_snapshot()
  let output = metrics_endpoint.render(snapshot, catalog)
  let assert Some(info) = model_catalog.find(catalog, "gpt-4")
  let expected_cost = model_catalog.cost_usd(info, 1000, 500, 800)
  assert string.contains(
    output,
    "pig_proxy_cost_usd{model=\"gpt-4\"} " <> format_cost(expected_cost),
  )
}

pub fn render_cost_uses_cache_read_price_test() {
  // 800 of the 1000 input tokens were cache hits: 200 bill at the input
  // price, 800 at the discounted cache-read price.
  let catalog_json =
    "{\"openai\":{\"id\":\"openai\",\"models\":{\"gpt-4\":{\"id\":\"gpt-4\",\"cost\":{\"input\":5,\"output\":15,\"cache_read\":0.5},\"limit\":{\"context\":128000,\"output\":16384}}}}}"
  let assert Ok(catalog) = model_catalog.parse(catalog_json)
  let output = metrics_endpoint.render(sample_snapshot(), catalog)
  let assert Some(info) = model_catalog.find(catalog, "gpt-4")
  let expected_cost = model_catalog.cost_usd(info, 1000, 500, 800)
  assert string.contains(
    output,
    "pig_proxy_cost_usd{model=\"gpt-4\"} " <> format_cost(expected_cost),
  )
}

pub fn render_cost_carries_fractional_overflow_test() {
  // A cost whose micro-dollar rounding overflows the fraction (0.9999996)
  // must carry into the whole part, producing "1.000000" rather than a
  // malformed "0.1000000".
  let catalog_json =
    "{\"openai\":{\"id\":\"openai\",\"models\":{\"gpt-4\":{\"id\":\"gpt-4\",\"cost\":{\"input\":999.9996,\"output\":0},\"limit\":{\"context\":1,\"output\":1}}}}}"
  let assert Ok(catalog) = model_catalog.parse(catalog_json)
  let output = metrics_endpoint.render(sample_snapshot(), catalog)
  assert string.contains(output, "pig_proxy_cost_usd{model=\"gpt-4\"} 1.000000")
  assert !string.contains(
    output,
    "pig_proxy_cost_usd{model=\"gpt-4\"} 0.1000000",
  )
}

fn format_cost(value: Float) -> String {
  let micros = float.round(value *. 1_000_000.0)
  let whole = micros |> int.divide(1_000_000) |> result.unwrap(0)
  let fraction = micros - whole * 1_000_000
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
