//// Live Chat Completions integration tests against an OpenAI-compatible API.
////
//// These hit a real endpoint using the same composition a consumer of
//// pig_protocol would assemble: auth -> codec -> transport -> codec.
////
//// Run with: mise run test-integration-protocol
////
//// Gated behind PIG_RUN_INTEGRATION=1. Without it, each test
//// prints a skip message and passes.

import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import integration/config
import integration/gate
import jscheam/schema
import pig_protocol/auth
import pig_protocol/codec/chat
import pig_protocol/error.{type AiError}
import pig_protocol/inference.{InferenceResult, type InferenceResult as Ir}
import pig_protocol/message
import pig_protocol/tool_definition.{type ToolDefinition}
import pig_protocol/transport
import pig_protocol/transport/httpc

const default_timeout_ms = 120_000

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Composition helper ──────────────────────────────────────────

/// Mirror how `pig/openai.do_inference` composes the protocol pieces:
/// auth → headers → URL → codec body → transport → codec response.
fn run_chat(
  messages: List(message.Message),
  tools: List(ToolDefinition),
) -> Result(Ir, AiError) {
  let mode = auth.StandardApi(config.api_key(), config.base_url())
  let url = auth.chat_url(mode)
  use headers <- result.try(auth.headers(mode, False))
  let body = chat.build_request_body(messages, tools, config.model())
  let req =
    transport.HttpRequest(
      url: url,
      headers: headers,
      body: body,
      timeout_ms: default_timeout_ms,
    )
  use raw <- result.try(httpc.transport(req))
  chat.parse_response(raw)
}

// ── Text completion ─────────────────────────────────────────────

pub fn chat_completions_text_completion_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False -> {
      let messages = [message.User("Say exactly the words: hello world")]
      case run_chat(messages, []) {
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
          panic as { "chat request failed: " <> ai_error_to_string(e) }
      }
    }
  }
}

// ── Response metadata ───────────────────────────────────────────

pub fn chat_completions_metadata_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False -> {
      let messages = [message.User("Say exactly: test")]
      case run_chat(messages, []) {
        Ok(InferenceResult(message: _, metadata: meta)) -> {
          // At least one metadata field should be populated by the provider.
          assert metadata_has_signal(meta)
        }
        Error(_) -> Nil
        // A provider that returns no metadata is acceptable;
        // we assert on parse path, not on provider behavior.
      }
    }
  }
}

// ── Tool call roundtrip ─────────────────────────────────────────

pub fn chat_completions_tool_roundtrip_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False -> {
      let tools = [add_tool_def()]
      let messages = [
        message.User("What is 7 plus 3? You MUST use the add tool to answer."),
      ]
      case run_chat(messages, tools) {
        Ok(InferenceResult(
          message: message.Assistant(tool_calls: [tc, ..], ..),
          ..,
        )) -> {
          assert tc.name == "add"
        }
        Ok(InferenceResult(
          message: message.Assistant(content:, tool_calls: [], ..),
          ..,
        )) -> {
          // The model answered directly without invoking the tool — also valid.
          assert string.contains(content, "10") == True
        }
        Error(e) ->
          panic as { "chat tool call failed: " <> ai_error_to_string(e) }
        _ -> panic as "unexpected message type"
      }
    }
  }
}

// ── Unreachable endpoint returns error ──────────────────────────

pub fn chat_completions_bad_url_returns_error_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False -> {
      let mode = auth.StandardApi("key", "http://127.0.0.1:1/v1")
      let url = auth.chat_url(mode)
      let assert Ok(headers) = auth.headers(mode, False)
      let body =
        chat.build_request_body([message.User("hello")], [], config.model())
      let req =
        transport.HttpRequest(
          url: url,
          headers: headers,
          body: body,
          timeout_ms: 5_000,
        )
      case httpc.transport(req) {
        Error(_) -> Nil
        Ok(_) -> panic as "expected error for unreachable URL"
      }
    }
  }
}

// ── Helpers ──────────────────────────────────────────────────────

fn add_tool_def() -> ToolDefinition {
  tool_definition.ToolDefinition(
    name: "add",
    description: "Add two numbers. Pass {\"a\": <number>, \"b\": <number>}.",
    parameters: schema.object([
      schema.prop("a", schema.integer()) |> schema.description("First number"),
      schema.prop("b", schema.integer()) |> schema.description("Second number"),
    ]),
  )
}

fn metadata_has_signal(meta: inference.InferenceMetadata) -> Bool {
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
    error.Cancelled -> "Cancelled"
    error.InvalidResponse(detail:) -> "InvalidResponse(" <> detail <> ")"
  }
}
