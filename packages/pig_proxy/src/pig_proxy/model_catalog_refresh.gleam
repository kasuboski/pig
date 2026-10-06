//// Pure scheduling policy for model catalog refresh failures.
////
//// Failure backoff uses equal jitter: each retry is uniformly selected from
//// [half the capped exponential delay, the full capped delay]. This spreads
//// independently running catalogs while never retrying immediately. A valid
//// Retry-After is a minimum and may exceed the normal refresh interval.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string

const retry_base_ms = 5000

/// Choose a failed-refresh delay. `failure_count` starts at one for the first
/// failure; `jitter_per_mille` is supplied by the runtime and must be 0..1000.
/// Retry-After is an uncapped minimum delay when positive.
pub fn failure_delay(
  failure_count: Int,
  normal_interval_ms: Int,
  jitter_per_mille: Int,
  retry_after_ms: Option(Int),
) -> Int {
  let cap = exponential_cap(failure_count, normal_interval_ms)
  let lower = int.max(1, cap / 2)
  let span = cap - lower
  let jitter = int.clamp(jitter_per_mille, 0, 1000)
  let jittered = lower + span * jitter / 1000
  case retry_after_ms {
    Some(minimum) if minimum > jittered -> minimum
    _ -> jittered
  }
}

/// A successful fetch clears the consecutive-failure sequence.
pub fn next_failure_count(success: Bool, previous_count: Int) -> Int {
  case success {
    True -> 0
    False -> previous_count + 1
  }
}

/// Parse Retry-After delta-seconds. HTTP-date parsing lives at the Erlang
/// boundary, where inets provides the RFC HTTP-date decoder.
pub fn retry_after_delta_ms(value: String) -> Option(Int) {
  case int.parse(string.trim(value)) {
    Ok(seconds) if seconds > 0 -> Some(seconds * 1000)
    _ -> None
  }
}

fn exponential_cap(failure_count: Int, normal_interval_ms: Int) -> Int {
  let normal = int.max(1, normal_interval_ms)
  cap_doubling(int.max(1, failure_count), retry_base_ms, normal)
}

fn cap_doubling(remaining: Int, current: Int, maximum: Int) -> Int {
  case remaining <= 1 || current >= maximum {
    True -> int.min(current, maximum)
    False -> cap_doubling(remaining - 1, int.min(current * 2, maximum), maximum)
  }
}
