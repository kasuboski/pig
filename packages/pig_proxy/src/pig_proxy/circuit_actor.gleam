//// Per-target circuit breaker actor.
////
//// Holds a `circuit.CircuitState` per upstream target and serialises
//// admission + transition decisions across concurrent requests (each mist
//// connection runs in its own process). The pure state machine lives in
//// `pig_proxy/circuit`; this module is the stateful owner that consults it.
////
//// Half-open admission is deliberately loose: a target whose cool-down has
//// elapsed becomes `HalfOpen` and every concurrent `Admit` is answered
//// `True` — there is no single-probe slot reservation. A committed success
//// closes the circuit; an exhausted budget reopens it.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import pig_proxy/circuit.{type CircuitState}
import pig_proxy/telemetry

/// Messages accepted by the circuit actor.
pub type CircuitMsg {
  /// Ask whether `target_id` may be attempted right now. Replies `True`
  /// for `Closed` and `HalfOpen` (cool-down elapsed) targets, `False` for
  /// targets whose circuit is `Open` within the cool-down.
  Admit(target_id: String, reply_to: process.Subject(Bool))
  /// Record one failure for `target_id` — sent only when a target's
  /// Per-Target Retry Budget is exhausted without a commit. May trip the
  /// circuit open at the configured threshold.
  RecordFailure(target_id: String)
  /// Record that `target_id` produced a committed (successful) outcome.
  /// Resets its circuit to closed.
  RecordSuccess(target_id: String)
  /// Snapshot the actor's per-target circuit states for observability.
  GetStatus(reply_to: process.Subject(CircuitStatus))
}

/// A snapshot of every target's circuit state, as a human-readable label.
pub type CircuitStatus {
  CircuitStatus(states: List(#(String, String)))
}

type CircuitActorState {
  CircuitActorState(
    circuits: Dict(String, CircuitState),
    threshold: Int,
    cooldown_ms: Int,
  )
}

fn handle_message(state: CircuitActorState, msg: CircuitMsg) {
  case msg {
    Admit(target_id, reply_to) -> {
      let now = telemetry.system_time()
      let current = current_state(state.circuits, target_id)
      // Transition an open circuit to half-open if its cool-down has
      // elapsed, then decide admission from the resulting state.
      let transitioned = circuit.maybe_half_open(current, now, state.cooldown_ms)
      let admit = circuit.should_attempt(transitioned, now, state.cooldown_ms)
      let circuits = dict.insert(state.circuits, target_id, transitioned)
      process.send(reply_to, admit)
      actor.continue(CircuitActorState(..state, circuits:))
    }

    RecordFailure(target_id) -> {
      let now = telemetry.system_time()
      let current = current_state(state.circuits, target_id)
      let next = circuit.record_failure(current, state.threshold, now)
      actor.continue(CircuitActorState(
        ..state,
        circuits: dict.insert(state.circuits, target_id, next),
      ))
    }

    RecordSuccess(target_id) -> {
      let current = current_state(state.circuits, target_id)
      let next = circuit.record_success(current)
      actor.continue(CircuitActorState(
        ..state,
        circuits: dict.insert(state.circuits, target_id, next),
      ))
    }

    GetStatus(reply_to) -> {
      let states =
        state.circuits
        |> dict.to_list
        |> list.map(fn(entry) {
          let #(target_id, circuit_state) = entry
          #(target_id, state_label(circuit_state))
        })
      process.send(reply_to, CircuitStatus(states:))
      actor.continue(state)
    }
  }
}

/// A target with no recorded state starts closed.
fn current_state(
  circuits: Dict(String, CircuitState),
  target_id: String,
) -> CircuitState {
  case dict.get(circuits, target_id) {
    Ok(state) -> state
    Error(_) -> circuit.new()
  }
}

fn state_label(state: CircuitState) -> String {
  case state {
    circuit.Closed(_) -> "closed"
    circuit.Open(_, _) -> "open"
    circuit.HalfOpen -> "half_open"
  }
}

/// Start the circuit actor with a failure `threshold` and a `cooldown_ms`
/// cool-down before a half-open probe is admitted.
pub fn start(
  threshold: Int,
  cooldown_ms: Int,
) -> Result(process.Subject(CircuitMsg), actor.StartError) {
  let result =
    CircuitActorState(circuits: dict.new(), threshold:, cooldown_ms:)
    |> actor.new
    |> actor.on_message(handle_message)
    |> actor.start
  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Synchronously ask whether `target_id` may be attempted right now.
pub fn admit(
  circuit: process.Subject(CircuitMsg),
  target_id: String,
  timeout_ms: Int,
) -> Bool {
  actor.call(circuit, waiting: timeout_ms, sending: fn(reply_to) {
    Admit(target_id, reply_to)
  })
}

/// Asynchronously record one failure for `target_id` (fire-and-forget).
pub fn record_failure(
  circuit: process.Subject(CircuitMsg),
  target_id: String,
) -> Nil {
  process.send(circuit, RecordFailure(target_id))
}

/// Asynchronously record a success for `target_id`, resetting its circuit.
pub fn record_success(
  circuit: process.Subject(CircuitMsg),
  target_id: String,
) -> Nil {
  process.send(circuit, RecordSuccess(target_id))
}

/// Get a snapshot of every target's circuit state.
pub fn get_status(
  circuit: process.Subject(CircuitMsg),
  timeout_ms: Int,
) -> CircuitStatus {
  actor.call(circuit, waiting: timeout_ms, sending: fn(reply_to) {
    GetStatus(reply_to)
  })
}
