//// Centralized test harness for pig/agent tests.
////
//// Single place for mock providers, test tools, and state construction.
//// If the API boundary changes, update HERE — all tests follow.
////
//// Per TESTING_STRATEGY §Axiom 3: "If our API boundary changes,
//// we update *one* `check` function, instantly fixing hundreds of tests."

import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import jscheam/schema
import pig/ai/error
import pig/ai/message
import pig/ai/provider
import pig/ai/tool_definition
import pig/tool

// ── Public: test tools ───────────────────────────────────────────

/// A tool that echoes back the "msg" field from arguments.
pub fn echo_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "echo",
      description: "Echoes back",
      parameters: schema.object([]),
    ),
    handler: fn(args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
      let assert Ok(msg) =
        decode.run(args, decode.field("msg", decode.string, decode.success))
      Ok(json.object([#("echo", json.string(msg))]))
    },
  )
}

/// A tool that always fails.
pub fn failing_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "boom",
      description: "Always fails",
      parameters: schema.object([]),
    ),
    handler: fn(_) { Error(tool.ToolError(message: "tool exploded")) },
  )
}

// ── Public: mock providers ───────────────────────────────────────

/// Provider that returns a fixed response every call.
pub fn fixed_provider(
  response: message.Message,
) -> fn(List(message.Message), List(tool_definition.ToolDefinition)) ->
  Result(provider.InferenceResult, error.AiError) {
  fn(_msgs, _tools) { Ok(provider.from_message(response)) }
}

/// Provider that always fails.
pub fn failing_provider(
  _msgs: List(message.Message),
  _tools: List(tool_definition.ToolDefinition),
) -> Result(provider.InferenceResult, error.AiError) {
  Error(error.ApiError("provider failed"))
}

// ── Public: sequenced provider for runtime tests ──────────────────

/// Provider that returns responses in sequence.
/// Tracks position by counting assistant messages in the history it receives.
pub fn sequenced_provider_for_actor(
  responses: List(message.Message),
) -> fn(List(message.Message), List(tool_definition.ToolDefinition)) ->
  Result(provider.InferenceResult, error.AiError) {
  fn(msgs, _tools) {
    let idx = count_assistant_messages(msgs)
    case nth(responses, idx) {
      Ok(msg) -> Ok(provider.from_message(msg))
      Error(_) ->
        Error(error.ApiError(
          "mock: no response at index " <> int.to_string(idx),
        ))
    }
  }
}

fn nth(lst: List(a), idx: Int) -> Result(a, Nil) {
  lst |> list.drop(idx) |> list.first
}

fn count_assistant_messages(msgs: List(message.Message)) -> Int {
  msgs
  |> list.filter(fn(m) {
    case m {
      message.Assistant(..) -> True
      _ -> False
    }
  })
  |> list.length()
}

import gleam/int
