//// Retry logic: exponential backoff with jitter, retryable status
//// classification, and `Retry-After` header parsing.
////
//// All functions here are pure — the actual retry loop lives in the
//// proxy request handler which calls `backoff_delay` to decide how long
//// to wait between attempts.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// HTTP status codes that warrant a retry.
fn retryable_statuses() -> List(Int) {
  [429, 500, 502, 503, 504]
}

/// Whether an HTTP status code is transient and worth retrying.
pub fn is_retryable_status(status: Int) -> Bool {
  list.contains(retryable_statuses(), status)
}

/// Integer power: base^exponent (exponent >= 0).
fn int_power(base: Int, exponent: Int) -> Int {
  case exponent {
    0 -> 1
    n -> base * int_power(base, n - 1)
  }
}

/// Calculate an exponential backoff delay with full jitter.
///
/// `attempt` is zero-indexed (0 = first retry). The base delay doubles
/// each attempt, capped at `max_ms`. Jitter is applied by multiplying
/// by a pseudo-random factor in [0, 1) derived from the attempt number
/// so the function stays pure (no side effects).
///
/// Formula: `min(base_ms * 2^attempt, max_ms) * jitter_factor`
pub fn backoff_delay(attempt: Int, base_ms: Int, max_ms: Int) -> Int {
  let exponential = base_ms * int_power(2, attempt)
  let capped = case exponential > max_ms {
    True -> max_ms
    False -> exponential
  }
  // Deterministic jitter: alternates between 50%, 75%, and 100% of the
  // capped delay based on the attempt number. This keeps the function
  // pure while still spreading retries across time.
  let jitter_factor = case attempt % 3 {
    0 -> 50
    1 -> 75
    _ -> 100
  }
  capped * jitter_factor / 100
}

/// Parse a `Retry-After` header value.
///
/// The header can be either:
///   - An integer number of seconds (e.g. `"120"`)
///   - An HTTP-date (e.g. `"Wed, 21 Oct 2025 07:28:00 GMT"`)
///
/// For HTTP-dates we return `None` (parsing RFC 7231 dates is out of
/// scope for the pure core; the handler can fall back to backoff_delay).
pub fn parse_retry_after(header_value: String) -> Option(Int) {
  case int.parse(string.trim(header_value)) {
    Ok(seconds) -> Some(seconds * 1000)
    Error(_) -> None
  }
}

/// Decide the delay for a retry attempt.
///
/// If the upstream provided a `Retry-After` header, use that (clamped to
/// `max_ms`). Otherwise, use `backoff_delay`.
pub fn retry_delay(
  attempt: Int,
  base_ms: Int,
  max_ms: Int,
  retry_after_header: Option(String),
) -> Int {
  case retry_after_header {
    Some(value) ->
      case parse_retry_after(value) {
        Some(ms) ->
          case ms > max_ms {
            True -> max_ms
            False -> ms
          }
        None -> backoff_delay(attempt, base_ms, max_ms)
      }
    None -> backoff_delay(attempt, base_ms, max_ms)
  }
}
