import gleam/option.{None, Some}
import gleeunit
import pig_proxy/retry

pub fn main() -> Nil {
  gleeunit.main()
}

// ── is_retryable_status ─────────────────────────────────────────

pub fn is_retryable_status_429_test() {
  assert True == retry.is_retryable_status(429)
}

pub fn is_retryable_status_500_test() {
  assert True == retry.is_retryable_status(500)
}

pub fn is_retryable_status_502_test() {
  assert True == retry.is_retryable_status(502)
}

pub fn is_retryable_status_503_test() {
  assert True == retry.is_retryable_status(503)
}

pub fn is_retryable_status_504_test() {
  assert True == retry.is_retryable_status(504)
}

pub fn is_retryable_status_200_test() {
  assert False == retry.is_retryable_status(200)
}

pub fn is_retryable_status_404_test() {
  assert False == retry.is_retryable_status(404)
}

pub fn is_retryable_status_401_test() {
  assert False == retry.is_retryable_status(401)
}

// ── backoff_delay ───────────────────────────────────────────────

pub fn backoff_delay_attempt_0_test() {
  // base=100, attempt=0: 100 * 2^0 = 100, jitter 50% → 50
  assert 50 == retry.backoff_delay(0, 100, 10_000)
}

pub fn backoff_delay_attempt_1_test() {
  // base=100, attempt=1: 100 * 2^1 = 200, jitter 75% → 150
  assert 150 == retry.backoff_delay(1, 100, 10_000)
}

pub fn backoff_delay_attempt_2_test() {
  // base=100, attempt=2: 100 * 2^2 = 400, jitter 100% → 400
  assert 400 == retry.backoff_delay(2, 100, 10_000)
}

pub fn backoff_delay_capped_at_max_test() {
  // base=100, attempt=10: 100 * 2^10 = 102400, capped at 500
  // 10 % 3 = 1 → jitter 75% → 500 * 75 / 100 = 375
  assert 375 == retry.backoff_delay(10, 100, 500)
}

pub fn backoff_delay_attempt_3_cycles_jitter_test() {
  // attempt=3: 3 % 3 = 0 → jitter 50%, 100 * 2^3 = 800, 800 * 50% = 400
  assert 400 == retry.backoff_delay(3, 100, 10_000)
}

// ── parse_retry_after ───────────────────────────────────────────

pub fn parse_retry_after_integer_test() {
  // "120" → 120 seconds → 120_000 ms
  assert Some(120_000) == retry.parse_retry_after("120")
}

pub fn parse_retry_after_with_whitespace_test() {
  assert Some(30_000) == retry.parse_retry_after("  30  ")
}

pub fn parse_retry_after_http_date_test() {
  assert None == retry.parse_retry_after("Wed, 21 Oct 2025 07:28:00 GMT")
}

pub fn parse_retry_after_invalid_test() {
  assert None == retry.parse_retry_after("not-a-number")
}

// ── retry_delay ─────────────────────────────────────────────────

pub fn retry_delay_with_retry_after_header_test() {
  // Retry-After: "5" → 5000 ms, clamped to max 10_000 → 5000
  assert 5000 == retry.retry_delay(0, 100, 10_000, Some("5"))
}

pub fn retry_delay_retry_after_clamped_to_max_test() {
  // Retry-After: "30" → 30000 ms, clamped to max 10_000 → 10_000
  assert 10_000 == retry.retry_delay(0, 100, 10_000, Some("30"))
}

pub fn retry_delay_without_retry_after_uses_backoff_test() {
  // No Retry-After → backoff_delay(0, 100, 10_000) = 50
  assert 50 == retry.retry_delay(0, 100, 10_000, None)
}

pub fn retry_delay_invalid_retry_after_falls_back_to_backoff_test() {
  // Invalid Retry-After → falls back to backoff_delay(1, 100, 10_000) = 150
  assert 150 == retry.retry_delay(1, 100, 10_000, Some("invalid"))
}
