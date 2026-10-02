//// Opt-in local acceptance tests for the complete subscriptions host.

import envoy
import gleam/io

@external(erlang, "pig_subscriptions_acceptance_ffi", "run")
fn run_acceptance() -> Nil

pub fn subscriptions_host_loopback_acceptance_test() -> Nil {
  case envoy.get("PIG_RUN_SUBSCRIPTIONS_INTEGRATION") {
    Ok("1") -> run_acceptance()
    _ ->
      io.println(
        "[SKIP] subscriptions host loopback acceptance (set PIG_RUN_SUBSCRIPTIONS_INTEGRATION=1)",
      )
  }
}
