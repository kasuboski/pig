import gleam/list
import gleeunit
import pig_proxy/circuit_actor

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Admission ───────────────────────────────────────────────────

pub fn admit_allows_unknown_target_test() {
  let assert Ok(c) = circuit_actor.start(3, 0)
  assert circuit_actor.admit(c, "openai", 2000) == True
}

pub fn admit_allows_target_below_failure_threshold_test() {
  let assert Ok(c) = circuit_actor.start(3, 0)
  circuit_actor.record_failure(c, "openai")
  circuit_actor.record_failure(c, "openai")
  assert circuit_actor.admit(c, "openai", 2000) == True
}

pub fn admit_blocks_target_once_threshold_reached_test() {
  // Large cool-down so an opened circuit stays open for the assertion.
  let assert Ok(c) = circuit_actor.start(3, 1_000_000)
  circuit_actor.record_failure(c, "openai")
  circuit_actor.record_failure(c, "openai")
  circuit_actor.record_failure(c, "openai")
  assert circuit_actor.admit(c, "openai", 2000) == False
}

// ── Per-target isolation ────────────────────────────────────────

pub fn circuit_state_is_per_target_test() {
  let assert Ok(c) = circuit_actor.start(1, 1_000_000)
  circuit_actor.record_failure(c, "openai")
  // "openai" is open, "ollama" is unaffected.
  assert circuit_actor.admit(c, "openai", 2000) == False
  assert circuit_actor.admit(c, "ollama", 2000) == True
}

// ── Recovery ────────────────────────────────────────────────────

pub fn open_circuit_recovers_to_half_open_after_cooldown_test() {
  // Zero cool-down: an opened circuit becomes half-open on the next admit,
  // so concurrent probes are admitted (no single-slot reservation).
  let assert Ok(c) = circuit_actor.start(1, 0)
  circuit_actor.record_failure(c, "openai")
  assert circuit_actor.admit(c, "openai", 2000) == True
  // A second concurrent probe is also admitted while half-open.
  assert circuit_actor.admit(c, "openai", 2000) == True
}

pub fn record_success_resets_circuit_within_cooldown_test() {
  let assert Ok(c) = circuit_actor.start(1, 1_000_000)
  circuit_actor.record_failure(c, "openai")
  assert circuit_actor.admit(c, "openai", 2000) == False
  circuit_actor.record_success(c, "openai")
  assert circuit_actor.admit(c, "openai", 2000) == True
}

pub fn record_failure_after_success_reopens_circuit_test() {
  let assert Ok(c) = circuit_actor.start(1, 1_000_000)
  circuit_actor.record_failure(c, "openai")
  circuit_actor.record_success(c, "openai")
  // A fresh failure trips it open again.
  circuit_actor.record_failure(c, "openai")
  assert circuit_actor.admit(c, "openai", 2000) == False
}

// ── Observability ───────────────────────────────────────────────

pub fn get_status_reports_per_target_state_test() {
  let assert Ok(c) = circuit_actor.start(1, 1_000_000)
  circuit_actor.record_failure(c, "openai")
  let status = circuit_actor.get_status(c, 2000)
  let openai_state =
    list.find(status.states, fn(entry) { entry.0 == "openai" })
  let assert Ok(#("openai", "open")) = openai_state
}
