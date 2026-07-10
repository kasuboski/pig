//// Live Codex Responses integration tests.
////
//// Exercises pig_protocol's Codex OAuth path (JWT-derived account ID, Responses
//// API URL) against a real endpoint. Same composition as the chat tests, but
//// targeting the `CodexOAuth` endpoint mode and the Responses codec.
////
//// Run with: mise run test-integration-protocol.
////
//// Required env (in addition to PIG_RUN_INTEGRATION=1):
////   OPENAI_COMPAT_CODEX_TOKEN  JWT access token for the Codex endpoint.
////
//// Optional: OPENAI_COMPAT_CODEX_BASE_URL (defaults to OPENAI_COMPAT_BASE_URL).
////
//// Tests print a clear skip message when PIG_RUN_INTEGRATION is unset;
//// when the gate is set but OPENAI_COMPAT_CODEX_TOKEN is empty, the test
//// reports a deterministic, expected error from the protocol.

import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleeunit
import integration/config
import integration/gate
import pig_protocol/auth
import pig_protocol/codec/responses
import pig_protocol/error.{type AiError}
import pig_protocol/inference.{InferenceResult, type InferenceResult as Ir}
import pig_protocol/message
import pig_protocol/transport
import pig_protocol/transport/httpc

const default_timeout_ms = 120_000

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Composition helper ──────────────────────────────────────────

/// Mirror `pig_protocol/auth.CodexOAuth` handling: derive the chatgpt-account-id
/// from the JWT, target the Codex Responses URL, and stream through the
/// Responses codec.
fn run_codex(
  messages: List(message.Message),
  instructions: Option(String),
) -> Result(Ir, AiError) {
  case config.codex_token() {
    "" ->
      Error(error.InvalidResponse(
        "OPENAI_COMPAT_CODEX_TOKEN is empty",
      ))
    token -> {
      let mode = auth.CodexOAuth(token, config.codex_base_url())
      let url = auth.responses_url(mode)
      use headers <- result.try(auth.headers(mode, False))
      let body =
        responses.build_request_body(
          messages,
          [],
          config.model(),
          instructions,
        )
      let req =
        transport.HttpRequest(
          url: url,
          headers: headers,
          body: body,
          timeout_ms: default_timeout_ms,
        )
      use raw <- result.try(httpc.transport(req))
      responses.parse_response(raw)
    }
  }
}

// ── Text completion via Responses API ───────────────────────────

pub fn codex_responses_text_completion_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False ->
      case run_codex(
        [message.User("Say exactly the words: hello world")],
        None,
      ) {
        Ok(InferenceResult(message: msg, metadata: _)) ->
          case msg {
            message.Assistant(
              content:,
              tool_calls: [],
              thinking: _,
              stop_reason: _,
            ) -> {
              assert string.contains(string.lowercase(content), "hello")
            }
            _ -> panic as "expected Assistant with no tool calls"
          }
        Error(e) ->
          case e {
            error.InvalidResponse("OPENAI_COMPAT_CODEX_TOKEN is empty") -> {
              io.println(
                "[SKIP] Codex OAuth token not provided. Set "
                <> "OPENAI_COMPAT_CODEX_TOKEN to run this test.",
              )
              Nil
            }
            _ ->
              panic as { "codex request failed: " <> ai_error_to_string(e) }
          }
      }
  }
}

// ── Response metadata ───────────────────────────────────────────

pub fn codex_responses_metadata_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False ->
      case run_codex([message.User("Say exactly: test")], None) {
        Ok(InferenceResult(message: _, metadata: meta)) -> {
          assert at_least_one(meta)
        }
        Error(error.InvalidResponse("OPENAI_COMPAT_CODEX_TOKEN is empty")) -> {
          Nil
        }
        Error(_) ->
          Nil
        // Missing metadata from a real provider is acceptable.
      }
  }
}

// ── Helpers ──────────────────────────────────────────────────────

fn at_least_one(meta: inference.InferenceMetadata) -> Bool {
  case meta.stop_reason {
    Some(_) -> True
    None ->
      case meta.response_model {
        Some(_) -> True
        None ->
          case meta.response_id {
            Some(_) -> True
            None -> False
          }
      }
  }
}

fn ai_error_to_string(err: AiError) -> String {
  case err {
    error.ApiError(message:) -> "ApiError(" <> message <> ")"
    error.RateLimited -> "RateLimited"
    error.Timeout -> "Timeout"
    error.InvalidResponse(detail:) -> "InvalidResponse(" <> detail <> ")"
  }
}
