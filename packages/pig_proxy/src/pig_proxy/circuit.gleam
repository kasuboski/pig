//// Circuit breaker: tracks consecutive failures per provider model and
//// opens the circuit after a threshold, blocking requests for a cool-down
//// period before allowing a half-open probe.
////
//// State transitions:
////
////   Closed ──(threshold failures)──> Open
////   Open   ──(cool-down elapsed)──> HalfOpen
////   HalfOpen ──(success)──> Closed
////   HalfOpen ──(failure)──> Open
////
//// All functions are pure — the state is held by an actor that calls
//// these functions to update and query the circuit.

/// The state of a circuit breaker for a single provider model.
pub type CircuitState {
  /// Circuit is closed — requests flow normally.
  Closed(failure_count: Int)
  /// Circuit is open — requests are blocked until the cool-down elapses.
  Open(opened_at_ms: Int, failure_count: Int)
  /// Circuit is half-open — a single probe request is allowed.
  HalfOpen
}

/// Create a fresh closed circuit.
pub fn new() -> CircuitState {
  Closed(failure_count: 0)
}

/// Record a successful request. Resets the circuit to closed.
pub fn record_success(_state: CircuitState) -> CircuitState {
  Closed(failure_count: 0)
}

/// Record a failed request. May trip the circuit open if the threshold
/// is reached.
pub fn record_failure(
  state: CircuitState,
  threshold: Int,
  now_ms: Int,
) -> CircuitState {
  case state {
    Closed(failure_count:) -> {
      let new_count = failure_count + 1
      case new_count >= threshold {
        True -> Open(opened_at_ms: now_ms, failure_count: new_count)
        False -> Closed(failure_count: new_count)
      }
    }
    HalfOpen ->
      Open(opened_at_ms: now_ms, failure_count: threshold)
    Open(opened_at_ms:, failure_count:) ->
      Open(opened_at_ms:, failure_count: failure_count + 1)
  }
}

/// Whether the circuit is currently blocking requests.
///
/// An open circuit blocks until the cool-down elapses, then transitions
/// to half-open (admitting attempts again). A half-open circuit admits
/// attempts; the circuit actor admits concurrent probes with no
/// single-slot reservation. A closed circuit never blocks.
pub fn is_open(
  state: CircuitState,
  now_ms: Int,
  cooldown_ms: Int,
) -> Bool {
  case state {
    Closed(_) -> False
    HalfOpen -> False
    Open(opened_at_ms:, ..) -> now_ms - opened_at_ms < cooldown_ms
  }
}

/// Whether a request should be allowed through.
///
/// Returns `True` for closed and half-open circuits, and for open
/// circuits whose cool-down has elapsed (which transitions to half-open).
pub fn should_attempt(
  state: CircuitState,
  now_ms: Int,
  cooldown_ms: Int,
) -> Bool {
  !is_open(state, now_ms, cooldown_ms)
}

/// Transition an open circuit to half-open if the cool-down has elapsed.
/// Returns the (possibly updated) state.
pub fn maybe_half_open(
  state: CircuitState,
  now_ms: Int,
  cooldown_ms: Int,
) -> CircuitState {
  case state {
    Open(opened_at_ms:, ..) ->
      case now_ms - opened_at_ms >= cooldown_ms {
        True -> HalfOpen
        False -> state
      }
    Closed(_) -> state
    HalfOpen -> state
  }
}

/// Get the current failure count for observability.
pub fn failure_count(state: CircuitState) -> Int {
  case state {
    Closed(failure_count:) -> failure_count
    Open(failure_count:, ..) -> failure_count
    HalfOpen -> 0
  }
}

/// Whether the circuit is currently in half-open state.
pub fn is_half_open(state: CircuitState) -> Bool {
  case state {
    HalfOpen -> True
    _ -> False
  }
}
