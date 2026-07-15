//// Live integration test: the proxy forwards a Chat Completions request.
////
//// Boots the full proxy (supervisor tree + mist) and POSTs a real Chat
//// Completions request through it to a configured OpenAI-compatible
//// upstream, asserting the proxied response is 200. This exercises the
//// entire request-execution path (transport seam, header injection,
//// retry/fallback, telemetry) against a live endpoint.
////
//// Required env (in addition to PIG_RUN_INTEGRATION=1):
////   OPENAI_COMPAT_BASE_URL — upstream base URL (incl. /v1)
////   OPENAI_COMPAT_API_KEY  — upstream key (default "ollama")
////   OPENAI_COMPAT_MODEL    — model slug (default "gemopuse4b")
////
//// Run with: mise run test-integration-proxy
////
//// Gated behind PIG_RUN_INTEGRATION=1. Without it, the test prints a skip
//// message and passes.

import gleam/erlang/process
import gleam/int
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

/// A Chat Completions request proxied through pig_proxy returns 200 from the
/// configured upstream.
pub fn proxy_forwards_chat_completion_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False -> {
      let cfg =
        proxy_config.from_env()
        |> proxy_config.with_port(config.base_port() + 1)
      let state = runtime.start(cfg)
      server.start(state)
      // Let the listener bind.
      process.sleep(1000)

      let url =
        "http://localhost:"
        <> int.to_string(cfg.port)
        <> "/v1/chat/completions"
      let body =
        "{\"model\":\""
        <> config.model()
        <> "\",\"messages\":[{\"role\":\"user\",\"content\":\"Say exactly: hello\"}]}"
      case
        hackney.sync_request(
          "POST",
          url,
          [#("content-type", "application/json")],
          body,
          120_000,
        )
      {
        hackney.OkResponse(status:, ..) -> {
          let assert 200 = status
          Nil
        }
        hackney.ErrorResponse(reason:) ->
          panic as { "upstream/transport error: " <> reason }
      }
    }
  }
}
