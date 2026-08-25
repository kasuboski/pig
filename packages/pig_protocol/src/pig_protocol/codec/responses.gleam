//// Codec for the OpenAI Responses API (`/v1/responses`) and the
//// equivalent ChatGPT Codex route (`/codex/responses`).
////
//// Pure JSON in, structured Gleam out. No IO. Composed by callers
//// with `pig_protocol/auth`, `pig_protocol/transport`, and `pig_protocol/sse`.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import jscheam/schema
import pig_protocol/error.{type AiError}
import pig_protocol/inference.{
  type InferenceResult, InferenceMetadata, InferenceResult,
}
import pig_protocol/message.{type Message, type ToolCall}
import pig_protocol/stop_reason
import pig_protocol/thinking.{type ThinkingLevel}
import pig_protocol/tool_definition.{type ToolDefinition}

/// Build the JSON request body for the OpenAI Responses API.
///
/// Messages are mapped to the Responses `input` format:
/// - `User` -> `input` message with `input_text` content.
/// - `System` -> ignored; pass system prompt via `instructions`.
/// - `Assistant` -> `input` assistant message with `output_text` content.
/// - `Tool` -> `function_call_output` item.
/// Pure function — no IO.
pub fn build_request_body(
  messages: List(Message),
  tools: List(ToolDefinition),
  model: String,
  instructions: Option(String),
) -> String {
  build_request_body_with_thinking(messages, tools, model, instructions, None)
}

/// Build a Responses request body for an SSE response.
pub fn build_stream_request_body(
  messages: List(Message),
  tools: List(ToolDefinition),
  model: String,
  instructions: Option(String),
) -> String {
  build_stream_request_body_with_thinking(
    messages,
    tools,
    model,
    instructions,
    None,
  )
}

/// Build a streaming Responses request with an optional thinking level.
pub fn build_stream_request_body_with_thinking(
  messages: List(Message),
  tools: List(ToolDefinition),
  model: String,
  instructions: Option(String),
  thinking_level: Option(ThinkingLevel),
) -> String {
  build_request_body_with_thinking_and_stream(
    messages,
    tools,
    model,
    instructions,
    thinking_level,
    True,
  )
}

/// Build a Responses API request with an optional thinking level.
///
/// OpenAI receives this as `reasoning.effort`. When thinking is enabled the
/// request also asks for an automatic provider-generated reasoning summary.
/// Unsupported levels are reported by the provider API.
pub fn build_request_body_with_thinking(
  messages: List(Message),
  tools: List(ToolDefinition),
  model: String,
  instructions: Option(String),
  thinking_level: Option(ThinkingLevel),
) -> String {
  build_request_body_with_thinking_and_stream(
    messages,
    tools,
    model,
    instructions,
    thinking_level,
    False,
  )
}

fn build_request_body_with_thinking_and_stream(
  messages: List(Message),
  tools: List(ToolDefinition),
  model: String,
  instructions: Option(String),
  thinking_level: Option(ThinkingLevel),
  streaming: Bool,
) -> String {
  let input_items = list.flat_map(messages, input_item_to_json)
  let required = [
    #("model", json.string(model)),
    #("store", json.bool(False)),
    #("stream", json.bool(streaming)),
    #("input", json.preprocessed_array(input_items)),
    #("tool_choice", json.string("auto")),
    #("parallel_tool_calls", json.bool(True)),
    #("include", json.array(["reasoning.encrypted_content"], json.string)),
  ]
  let with_thinking = case thinking_level {
    Some(thinking.Off) -> [
      #(
        "reasoning",
        json.object([
          #("effort", json.string(thinking.to_openai_effort(thinking.Off))),
        ]),
      ),
      ..required
    ]
    Some(level) -> [
      #(
        "reasoning",
        json.object([
          #("effort", json.string(thinking.to_openai_effort(level))),
          #("summary", json.string("auto")),
        ]),
      ),
      ..required
    ]
    None -> required
  }
  let with_instructions = case instructions {
    Some(text) -> [#("instructions", json.string(text)), ..with_thinking]
    None -> with_thinking
  }
  let with_tools = case tools {
    [] -> with_instructions
    ts ->
      list.append(with_instructions, [#("tools", json.array(ts, tool_to_json))])
  }
  json.object(with_tools) |> json.to_string()
}

/// Parse an OpenAI Responses API JSON response into an InferenceResult.
/// Pure function — no IO.
pub fn parse_response(raw: String) -> Result(InferenceResult, AiError) {
  json.parse(from: raw, using: response_decoder())
  |> result.map_error(fn(err) {
    case err {
      json.UnexpectedEndOfInput
      | json.UnexpectedByte(_)
      | json.UnexpectedSequence(_) ->
        error.InvalidResponse("Failed to parse JSON response")
      json.UnableToDecode(_) ->
        error.InvalidResponse("Missing or invalid response fields")
    }
  })
}

// ─── Internal: JSON building ───────────────────────────────────

fn input_item_to_json(msg: Message) -> List(json.Json) {
  case msg {
    message.User(content:) -> [
      json.object([
        #("type", json.string("message")),
        #("role", json.string("user")),
        #(
          "content",
          json.preprocessed_array([
            json.object([
              #("type", json.string("input_text")),
              #("text", json.string(content)),
            ]),
          ]),
        ),
      ]),
    ]

    message.System(_) -> []

    // The Responses API requires each `function_call_output` to be preceded by
    // a matching `function_call` item, so assistant tool calls must be
    // serialized back into `input` (not just the assistant's text).
    message.Assistant(content:, tool_calls:, thinking: _, stop_reason: _) -> {
      let text_items = case content {
        "" -> []
        text -> [
          json.object([
            #("type", json.string("message")),
            #("role", json.string("assistant")),
            #(
              "content",
              json.preprocessed_array([
                json.object([
                  #("type", json.string("output_text")),
                  #("text", json.string(text)),
                  #("annotations", json.preprocessed_array([])),
                ]),
              ]),
            ),
            #("status", json.string("completed")),
          ]),
        ]
      }
      list.append(text_items, list.map(tool_calls, tool_call_to_json))
    }

    message.Tool(tool_call_id:, content:) -> [
      json.object([
        #("type", json.string("function_call_output")),
        #("call_id", json.string(tool_call_id)),
        #("output", json.string(content)),
      ]),
    ]
  }
}

fn tool_call_to_json(tc: ToolCall) -> json.Json {
  json.object([
    #("type", json.string("function_call")),
    #("call_id", json.string(tc.id)),
    #("name", json.string(tc.name)),
    #("arguments", json.string(tc.arguments_json)),
  ])
}

fn tool_to_json(td: ToolDefinition) -> json.Json {
  // The Responses API treats `strict` as optional and defaults to false,
  // so we omit it rather than send `false`/`null`.
  json.object([
    #("type", json.string("function")),
    #("name", json.string(td.name)),
    #("description", json.string(td.description)),
    #("parameters", schema.to_json(td.parameters)),
  ])
}

// ─── Internal: JSON parsing ────────────────────────────────────

fn response_decoder() -> decode.Decoder(InferenceResult) {
  use id <- decode.field("id", decode.string)
  use model <- decode.field("model", decode.string)
  use status <- decode.optional_field("status", "completed", decode.string)
  use output <- decode.field("output", decode.list(output_item_decoder()))
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(usage_decoder()),
  )

  let #(text, reasoning, tool_calls) =
    list.fold(output, #("", "", []), fn(acc, item) {
      case item {
        TextOutput(t) -> #(acc.0 <> t, acc.1, acc.2)
        ThinkingOutput(t) -> #(acc.0, acc.1 <> t, acc.2)
        FunctionCallOutput(tc) -> #(acc.0, acc.1, [tc, ..acc.2])
        IgnoredOutput -> acc
      }
    })
  let tool_calls = list.reverse(tool_calls)

  let stop_reason = case tool_calls {
    [] -> stop_reason.from_responses_status(status)
    _ -> stop_reason.ToolUse
  }

  let metadata =
    InferenceMetadata(
      response_id: Some(id),
      response_model: Some(model),
      stop_reason: Some(stop_reason),
      input_tokens: option.map(usage, fn(u) { u.input_tokens }),
      output_tokens: option.map(usage, fn(u) { u.output_tokens }),
    )

  let thinking = case reasoning {
    "" -> None
    text -> Some(message.Thinking(text))
  }

  let message =
    message.Assistant(
      content: text,
      tool_calls: tool_calls,
      thinking: thinking,
      stop_reason: Some(stop_reason),
    )

  decode.success(InferenceResult(message:, metadata:))
}

type OutputItem {
  TextOutput(text: String)
  ThinkingOutput(text: String)
  FunctionCallOutput(tool_call: ToolCall)
  IgnoredOutput
}

fn output_item_decoder() -> decode.Decoder(OutputItem) {
  use item_type <- decode.field("type", decode.string)
  case item_type {
    "message" -> message_output_decoder()
    "reasoning" -> reasoning_output_decoder()
    "function_call" -> function_call_output_decoder()
    _ -> decode.success(IgnoredOutput)
  }
}

fn message_output_decoder() -> decode.Decoder(OutputItem) {
  use content <- decode.field("content", decode.list(content_block_decoder()))
  let text =
    content
    |> list.filter_map(fn(block) {
      case block {
        TextBlock(t) -> Ok(t)
        _ -> Error(Nil)
      }
    })
    |> string.join("")
  decode.success(TextOutput(text))
}

fn reasoning_output_decoder() -> decode.Decoder(OutputItem) {
  use summary <- decode.optional_field(
    "summary",
    None,
    decode.optional(decode.list(reasoning_block_decoder())),
  )
  use content <- decode.optional_field(
    "content",
    None,
    decode.optional(decode.list(reasoning_block_decoder())),
  )
  let summary_text = option.unwrap(summary, []) |> string.join("\n\n")
  let content_text = option.unwrap(content, []) |> string.join("\n\n")
  let text = case summary_text {
    "" -> content_text
    _ -> summary_text
  }
  decode.success(ThinkingOutput(text))
}

fn reasoning_block_decoder() -> decode.Decoder(String) {
  use text <- decode.optional_field("text", "", decode.string)
  decode.success(text)
}

type ContentBlock {
  TextBlock(String)
  OtherBlock
}

fn content_block_decoder() -> decode.Decoder(ContentBlock) {
  use block_type <- decode.field("type", decode.string)
  case block_type {
    "output_text" -> {
      use text <- decode.field("text", decode.string)
      decode.success(TextBlock(text))
    }
    "refusal" -> {
      use refusal <- decode.optional_field("refusal", "", decode.string)
      decode.success(TextBlock(refusal))
    }
    _ -> decode.success(OtherBlock)
  }
}

fn function_call_output_decoder() -> decode.Decoder(OutputItem) {
  // The Responses API pairs tool results by `call_id`, not the item `id`
  // (`fc_...`). Capture `call_id` so round-tripped tool results match.
  use call_id <- decode.field("call_id", decode.string)
  use name <- decode.field("name", decode.string)
  use arguments <- decode.field("arguments", decode.string)
  decode.success(
    FunctionCallOutput(message.ToolCall(
      id: call_id,
      name:,
      arguments_json: arguments,
    )),
  )
}

type Usage {
  Usage(input_tokens: Int, output_tokens: Int, total_tokens: Int)
}

fn usage_decoder() -> decode.Decoder(Usage) {
  use input_tokens <- decode.field("input_tokens", decode.int)
  use output_tokens <- decode.field("output_tokens", decode.int)
  use total_tokens <- decode.field("total_tokens", decode.int)
  decode.success(Usage(input_tokens:, output_tokens:, total_tokens:))
}
