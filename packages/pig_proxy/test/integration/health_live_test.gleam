//// Live integration test: the full proxy runtime boots and serves.
////
//// Starts the real proxy — the entire supervisor tree (circuit, model
//// catalog, metrics, and the credential sub-tree when configured) plus the
//// mist HTTP server — and asserts `/health` responds. This needs no
//// upstream provider: it validates that `runtime.start` + `server.start`
//// bring the system up, the part unit tests can't reach.
////
//// Run with: mise run test-integration-proxy
////
//// Gated behind PIG_RUN_INTEGRATION=1. Without it, the test prints a skip
//// message and passes.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/string
import gleeunit
import pig_proxy/config as proxy_config
import pig_proxy/hackney
import pig_proxy/runtime
import pig_proxy/server
import integration/config
import integration/gate

pub fn main() -> Nil {
  gleeunit.main()
}

/// The full runtime tree boots and mist serves `/health` with 200 / "ok".
pub fn health_endpoint_serves_after_boot_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False -> {
      let cfg =
        proxy_config.from_env()
        |> proxy_config.with_port(config.base_port())
      let state = runtime.start(cfg)
      server.start(state)
      // Let the listener bind.
      process.sleep(1000)

      let url =
        "http://localhost:"
        <> int.to_string(cfg.port)
        <> "/health"
      let assert hackney.OkResponse(status: 200, body:, ..) =
        hackney.sync_request("GET", url, [], "", 30_000)
      let assert Ok(text) = bit_array.to_string(body)
      assert string.contains(text, "ok")
      Nil
    }
  }
}
