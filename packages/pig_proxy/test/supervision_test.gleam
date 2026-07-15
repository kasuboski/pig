//// Supervision behaviour for the named long-lived actors.
////
//// These tests pin the property that motivated the supervisor tree: when a
//// supervised actor crashes, the supervisor restarts it and it re-registers
//// under the SAME name, so callers resolving by name transparently reach
//// the new process (and degrade to None only during the brief restart
//// window). The request path relies on this (`server.resolve_named`).

import gleam/erlang/process
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleeunit
import pig_proxy/circuit_actor

pub fn main() -> Nil {
  gleeunit.main()
}

/// A named supervised actor restarts under the same name after a crash, so
/// `process.named` (and thus `resolve_named`) routes to the new process.
pub fn supervised_named_actor_restarts_under_same_name_test() {
  let name = process.new_name("circuit_supervision_test")
  let sup =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(supervision.worker(fn() {
      circuit_actor.start_named(1, 1_000_000, name)
    }))

  let assert Ok(_) = static_supervisor.start(sup)

  let assert Ok(pid_a) = process.named(name)
  // Crash the actor. The supervisor must restart it under `name`.
  process.kill(pid_a)

  let assert Ok(pid_b) = poll_for_new_pid(name, pid_a, 40)
  assert pid_b != pid_a

  // The restarted actor is reachable by name and answers normally
  // (a fresh circuit admits an unknown target).
  assert circuit_actor.admit(process.named_subject(name), "any-target", 1000)

  // The supervisor is linked to this test process, so it is torn down when
  // the process exits — no explicit kill (which would kill this process too).
  process.sleep(0)
}

/// Before the actor is (re)registered, the name resolves to None — the
/// degrade path callers fall back to.
pub fn unregistered_name_resolves_to_none_test() {
  let name = process.new_name("circuit_never_started_test")
  assert process.named(name) == Error(Nil)
}

/// Poll `process.named(name)` until it returns a pid different from
/// `old_pid`, up to `tries` × 50ms.
fn poll_for_new_pid(
  name: process.Name(a),
  old_pid: process.Pid,
  tries: Int,
) -> Result(process.Pid, Nil) {
  case process.named(name) {
    Ok(p) if p != old_pid -> Ok(p)
    _ ->
      case tries <= 0 {
        True -> Error(Nil)
        False -> {
          process.sleep(50)
          poll_for_new_pid(name, old_pid, tries - 1)
        }
      }
  }
}
