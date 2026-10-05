//// Opt-in local acceptance tests for the complete subscriptions host.

import envoy
import gleam/io
import support/acceptance

pub fn subscriptions_host_http_and_otlp_acceptance_test() -> Nil {
  case envoy.get("PIG_RUN_SUBSCRIPTIONS_INTEGRATION") {
    Ok("1") -> acceptance.run()
    _ ->
      io.println(
        "[SKIP] subscriptions host HTTP + OTLP acceptance (set PIG_RUN_SUBSCRIPTIONS_INTEGRATION=1)",
      )
  }
}
