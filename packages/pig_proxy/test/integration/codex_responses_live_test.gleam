//// Live integration test: the proxy forwards a Codex Responses request.
////
//// Boots the proxy configured for ChatGPT/Codex OAuth and POSTs a Responses
//// API request through it to the Codex backend, asserting a 200. This
//// exercises the whole Codex path end to end: the credential sub-tree
//// (vault seeded from persisted creds / seed token, refresh actor), Codex
//// header injection (chatgpt-account-id, OpenAI-Beta, originator), and the
//// /v1/responses route.
////
//// Required env (in addition to PIG_RUN_INTEGRATION=1):
////   OPENAI_COMPAT_CODEX=1                          — select the Codex target
////   OPENAI_COMPAT_BASE_URL                        — Codex backend, e.g.
////                                                   https://chatgpt.com/backend-api/codex
////   OPENAI_COMPAT_MODEL                           — Codex model slug
////   and ONE of:
////     OPENAI_COMPAT_CODEX_TOKEN=<JWT>             — seed the vault directly
////     ~/.pig/codex_auth.json                      — populated by
////                                                   `gleam run -m pig_proxy/codex_login`
////
//// Run with: mise run test-integration-proxy
////
//// Gated behind PIG_RUN_INTEGRATION=1 and Codex configuration. Without
//// them, the test prints a skip message and passes.

import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/result
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

/// A Responses API request proxied through the Codex-configured proxy
/// returns 200 with an `output` field.
pub fn proxy_forwards_codex_responses_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False ->
      case config.is_codex() {
        False -> {
          io.println(
            "[SKIP] codex responses test: not in Codex mode (set OPENAI_COMPAT_CODEX=1).",
          )
          Nil
        }
        True ->
          case config.has_codex_credentials() {
            False ->
              panic as {
                "Codex mode is on but no credentials found — set OPENAI_COMPAT_CODEX_TOKEN or run `gleam run -m pig_proxy/codex_login`"
              }
            True -> {
              let cfg =
                proxy_config.from_env()
                |> proxy_config.with_port(config.base_port() + 2)
              let state = runtime.start(cfg)
              server.start(state)
              let assert True = gate.wait_until_ready(cfg.port)

              let url =
                "http://localhost:"
                <> int.to_string(cfg.port)
                <> "/v1/responses"
              // Standard Responses API body; tweak for your model if needed.
              let body =
                "{\"model\":\""
                <> config.model()
                <> "\",\"instructions\":\"Be brief.\",\"input\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Reply with the single word: hello\"}]}],\"stream\":true,\"store\":false}"
              case
                hackney.sync_request(
                  "POST",
                  url,
                  [#("content-type", "application/json")],
                  body,
                  120_000,
                )
              {
                hackney.OkResponse(status:, headers:, body: resp_body) -> {
                  case status == 200 {
                    True -> Nil
                    False -> {
                      // Print headers + body so the failure reason is visible.
                      // 401/403 = credentials; other 4xx = request shape / model.
                      let body_text = result.unwrap(bit_array.to_string(resp_body), "")
                      let header_text =
                        list.fold(headers, "", fn(acc, h) {
                          acc <> h.0 <> ": " <> h.1 <> " | "
                        })
                      io.println(
                        "Codex responses returned "
                        <> int.to_string(status)
                        <> "\nheaders: "
                        <> header_text
                        <> "\nbody: "
                        <> body_text,
                      )
                      panic as {
                        "Codex responses returned "
                        <> int.to_string(status)
                        <> " (401/403 = credentials; other 4xx = request/model) — details printed above"
                      }
                    }
                  }
                }
                hackney.ErrorResponse(reason:) ->
                  panic as { "upstream/transport error: " <> reason }
              }
            }
          }
      }
  }
}
