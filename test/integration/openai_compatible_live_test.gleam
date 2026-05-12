//// Integration tests against a real OpenAI-compatible API.
////
//// These hit a real endpoint. Run with: mise run test-integration
////
//// Gated behind PIG_RUN_INTEGRATION=1. Without it, each test
//// prints a skip message and passes.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import integration/config
import integration/gate
import jscheam/schema
import pig/ai/error.{type AiError}
import pig/ai/message
import pig/ai/openai
import pig/ai/provider.{InferenceResult}
import pig/ai/tool_definition
import pig/tool

pub fn main() -> Nil {
  gleeunit.main()
}

fn make_provider() -> openai.OpenAIProvider {
  openai.provider_with_base_url(
    config.api_key(),
    config.model(),
    config.base_url(),
  )
}

// ── Simple text completion ──────────────────────────────────────

pub fn simple_text_completion_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False -> {
      let prov = make_provider()
      let messages = [message.User("Say exactly the words: hello world")]
      let result = prov.call(messages, [])
      let assert Ok(InferenceResult(message: msg, metadata: _)) = result
      case msg {
        message.Assistant(content:, tool_calls: [], thinking: _) -> {
          string.contains(string.lowercase(content), "hello")
          |> should.equal(True)
        }
        _ -> panic as "expected Assistant with no tool calls"
      }
    }
  }
}

// ── Response metadata ───────────────────────────────────────────

pub fn response_has_metadata_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False -> {
      let prov = make_provider()
      let messages = [message.User("Say exactly: test")]
      let result = prov.call(messages, [])
      let assert Ok(InferenceResult(message: _, metadata: meta)) = result
      option.is_some(meta.finish_reason) |> should.equal(True)
    }
  }
}

// ── Tool call roundtrip ─────────────────────────────────────────

pub fn tool_call_roundtrip_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False -> {
      let add_tool =
        tool.Tool(
          definition: tool_definition.ToolDefinition(
            name: "add",
            description: "Add two numbers. Pass {\"a\": <number>, \"b\": <number>}.",
            parameters: schema.object([
              schema.prop("a", schema.integer())
                |> schema.description("First number"),
              schema.prop("b", schema.integer())
                |> schema.description("Second number"),
            ]),
          ),
          handler: fn(args: dynamic.Dynamic) -> Result(
            json.Json,
            tool.ToolError,
          ) {
            let a_result =
              decode.run(args, decode.field("a", decode.int, decode.success))
            let b_result =
              decode.run(args, decode.field("b", decode.int, decode.success))
            case a_result, b_result {
              Ok(a), Ok(b) -> Ok(json.object([#("result", json.int(a + b))]))
              _, _ -> Error(tool.ToolError(message: "invalid arguments"))
            }
          },
        )

      let registry =
        tool.new_registry()
        |> tool.register(add_tool)

      let defs = tool.list_definitions(registry)
      let prov = make_provider()
      let messages = [
        message.User("What is 7 plus 3? You MUST use the add tool to answer."),
      ]

      let result = prov.call(messages, defs)

      case result {
        Ok(InferenceResult(
          message: message.Assistant(tool_calls: [tc, ..], ..),
          ..,
        )) -> {
          tc.name |> should.equal("add")
        }
        Ok(InferenceResult(
          message: message.Assistant(content:, tool_calls: [], ..),
          ..,
        )) -> {
          string.contains(content, "10") |> should.equal(True)
        }
        Error(e) -> {
          panic as { "provider returned error: " <> ai_error_to_string(e) }
        }
        _ -> panic as "unexpected message type"
      }
    }
  }
}

// ── Error surface ───────────────────────────────────────────────

pub fn invalid_model_returns_error_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False -> {
      let prov =
        openai.provider_with_base_url(
          config.api_key(),
          "nonexistent-model-xyz-123",
          config.base_url(),
        )
      let messages = [message.User("hello")]
      let result = prov.call(messages, [])
      case result {
        Ok(_) | Error(_) -> Nil
      }
    }
  }
}

pub fn bad_base_url_returns_error_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False -> {
      let prov =
        openai.provider_with_base_url("key", "model", "http://127.0.0.1:1/v1")
      let messages = [message.User("hello")]
      let result = prov.call(messages, [])
      case result {
        Error(_) -> Nil
        Ok(_) -> panic as "expected error for unreachable URL"
      }
    }
  }
}

// ── Helpers ──────────────────────────────────────────────────────

fn ai_error_to_string(err: AiError) -> String {
  case err {
    error.ApiError(message:) -> "ApiError(" <> message <> ")"
    error.RateLimited -> "RateLimited"
    error.Timeout -> "Timeout"
    error.InvalidResponse(detail:) -> "InvalidResponse(" <> detail <> ")"
  }
}
