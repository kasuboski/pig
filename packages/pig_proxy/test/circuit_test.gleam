import gleeunit
import pig_proxy/circuit

pub fn main() -> Nil {
  gleeunit.main()
}

// ── new ─────────────────────────────────────────────────────────

pub fn new_returns_closed_with_zero_failures_test() {
  let state = circuit.new()
  assert circuit.Closed(failure_count: 0) == state
}

// ── record_success ──────────────────────────────────────────────

pub fn record_success_on_closed_resets_test() {
  let state = circuit.Closed(failure_count: 3)
  let result = circuit.record_success(state)
  assert circuit.Closed(failure_count: 0) == result
}

pub fn record_success_on_open_resets_test() {
  let state = circuit.Open(opened_at_ms: 1000, failure_count: 5)
  let result = circuit.record_success(state)
  assert circuit.Closed(failure_count: 0) == result
}

pub fn record_success_on_half_open_resets_test() {
  let result = circuit.record_success(circuit.HalfOpen)
  assert circuit.Closed(failure_count: 0) == result
}

// ── record_failure ──────────────────────────────────────────────

pub fn record_failure_below_threshold_stays_closed_test() {
  let state = circuit.Closed(failure_count: 2)
  let result = circuit.record_failure(state, 5, 100)
  assert circuit.Closed(failure_count: 3) == result
}

pub fn record_failure_at_threshold_opens_circuit_test() {
  let state = circuit.Closed(failure_count: 4)
  let result = circuit.record_failure(state, 5, 100)
  assert circuit.Open(opened_at_ms: 100, failure_count: 5) == result
}

pub fn record_failure_on_half_open_opens_circuit_test() {
  let result = circuit.record_failure(circuit.HalfOpen, 5, 200)
  assert circuit.Open(opened_at_ms: 200, failure_count: 5) == result
}

pub fn record_failure_on_open_increments_count_test() {
  let state = circuit.Open(opened_at_ms: 100, failure_count: 5)
  let result = circuit.record_failure(state, 5, 200)
  assert circuit.Open(opened_at_ms: 100, failure_count: 6) == result
}

// ── is_open ─────────────────────────────────────────────────────

pub fn is_open_closed_returns_false_test() {
  assert False == circuit.is_open(circuit.Closed(failure_count: 0), 100, 1000)
}

pub fn is_open_half_open_returns_false_test() {
  assert False == circuit.is_open(circuit.HalfOpen, 100, 1000)
}

pub fn is_open_within_cooldown_returns_true_test() {
  let state = circuit.Open(opened_at_ms: 1000, failure_count: 5)
  assert True == circuit.is_open(state, 1500, 1000)
}

pub fn is_open_after_cooldown_returns_false_test() {
  let state = circuit.Open(opened_at_ms: 1000, failure_count: 5)
  assert False == circuit.is_open(state, 2500, 1000)
}

// ── should_attempt ──────────────────────────────────────────────

pub fn should_attempt_closed_returns_true_test() {
  assert True == circuit.should_attempt(circuit.Closed(failure_count: 0), 100, 1000)
}

pub fn should_attempt_open_within_cooldown_returns_false_test() {
  let state = circuit.Open(opened_at_ms: 1000, failure_count: 5)
  assert False == circuit.should_attempt(state, 1500, 1000)
}

pub fn should_attempt_open_after_cooldown_returns_true_test() {
  let state = circuit.Open(opened_at_ms: 1000, failure_count: 5)
  assert True == circuit.should_attempt(state, 2500, 1000)
}

// ── maybe_half_open ─────────────────────────────────────────────

pub fn maybe_half_open_after_cooldown_transitions_test() {
  let state = circuit.Open(opened_at_ms: 1000, failure_count: 5)
  let result = circuit.maybe_half_open(state, 2500, 1000)
  assert circuit.HalfOpen == result
}

pub fn maybe_half_open_within_cooldown_stays_open_test() {
  let state = circuit.Open(opened_at_ms: 1000, failure_count: 5)
  let result = circuit.maybe_half_open(state, 1500, 1000)
  assert circuit.Open(opened_at_ms: 1000, failure_count: 5) == result
}

pub fn maybe_half_open_closed_stays_closed_test() {
  let state = circuit.Closed(failure_count: 3)
  let result = circuit.maybe_half_open(state, 100, 1000)
  assert circuit.Closed(failure_count: 3) == result
}

pub fn maybe_half_open_half_open_stays_half_open_test() {
  let result = circuit.maybe_half_open(circuit.HalfOpen, 100, 1000)
  assert circuit.HalfOpen == result
}

// ── failure_count ───────────────────────────────────────────────

pub fn failure_count_closed_test() {
  assert 3 == circuit.failure_count(circuit.Closed(failure_count: 3))
}

pub fn failure_count_open_test() {
  assert 5 == circuit.failure_count(
    circuit.Open(opened_at_ms: 100, failure_count: 5),
  )
}

pub fn failure_count_half_open_test() {
  assert 0 == circuit.failure_count(circuit.HalfOpen)
}

// ── is_half_open ────────────────────────────────────────────────

pub fn is_half_open_true_test() {
  assert True == circuit.is_half_open(circuit.HalfOpen)
}

pub fn is_half_open_false_for_closed_test() {
  assert False == circuit.is_half_open(circuit.Closed(failure_count: 0))
}

pub fn is_half_open_false_for_open_test() {
  assert False == circuit.is_half_open(
    circuit.Open(opened_at_ms: 100, failure_count: 5),
  )
}
