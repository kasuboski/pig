import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit
import gleeunit/should
import pig_proxy/model_catalog_refresh as refresh

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn failure_schedule_uses_equal_jitter_and_caps_test() {
  let fixtures = [
    #("first lower boundary", 1, 60_000, 0, 2500),
    #("first upper boundary", 1, 60_000, 1000, 5000),
    #("second midpoint", 2, 60_000, 500, 7500),
    #("normal interval cap", 5, 12_000, 1000, 12_000),
    #("large count stays capped", 1000, 12_000, 0, 6000),
    #("minimum positive delay", 1, 1, 0, 1),
  ]
  list.each(fixtures, fn(fixture) {
    let #(_, failure_count, normal, jitter, expected) = fixture
    should.equal(check_delay(failure_count, normal, jitter, None), expected)
  })
}

pub fn retry_after_is_minimum_not_capped_test() {
  should.equal(refresh.failure_delay(1, 10_000, 0, Some(45_000)), 45_000)
  should.equal(refresh.failure_delay(1, 10_000, 0, Some(0)), 2500)
  should.equal(refresh.failure_delay(1, 10_000, 0, Some(-500)), 2500)
}

pub fn delta_seconds_parser_rejects_invalid_values_test() {
  should.equal(refresh.retry_after_delta_ms(" 12 "), Some(12_000))
  should.equal(refresh.retry_after_delta_ms("0"), None)
  should.equal(refresh.retry_after_delta_ms("-1"), None)
  should.equal(refresh.retry_after_delta_ms("invalid"), None)
}

fn check_delay(
  failure_count: Int,
  normal_interval_ms: Int,
  jitter_per_mille: Int,
  retry_after_ms: Option(Int),
) -> Int {
  refresh.failure_delay(
    failure_count,
    normal_interval_ms,
    jitter_per_mille,
    retry_after_ms,
  )
}

pub fn http_date_retry_after_uses_supplied_clock_test() {
  should.equal(
    retry_after_http_date_ms("Wed, 21 Oct 2025 07:28:00 GMT", 1_761_031_675_000),
    Some(5000),
  )
  should.equal(
    retry_after_http_date_ms("not-an-http-date", 1_761_031_675_000),
    None,
  )
}

@external(erlang, "pig_proxy_model_catalog_cache_ffi", "retry_after_http_date_ms")
fn retry_after_http_date_ms(value: String, now_ms: Int) -> Option(Int)

pub fn success_resets_consecutive_failure_count_test() {
  should.equal(refresh.next_failure_count(True, 27), 0)
  should.equal(refresh.next_failure_count(False, 3), 4)
}
