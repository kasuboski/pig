import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import jscheam/schema
import pig_protocol/error.{type AiError}
import pig_protocol/inference.{type InferenceResult, InferenceResult, InferenceMetadata, default_metadata}
import pig_protocol/message.{type Message}
import pig_protocol/stop_reason
import pig_protocol/tool_definition.{type ToolDefinition}

/// Build the JSON request body for the OpenAI Chat Completions API.
/// Pure function — no IO.
pub fn build_request_body(
  messages: List(Message),
  tools: List(ToolDefinition),
  model: String,
) -> String {
  let msg_entries =
    messages
    |> list.map(message_to_json)
  let base = [
    #("model", json.string(model)),
    #("messages", json.preprocessed_array(msg_entries)),
    #("stream", json.bool(False)),
  ]
  let with_tools = case tools {
    [] -> base
    ts ->
      base
      |> list.append([#("tools", json.array(ts, tool_to_json))])
  }
  json.object(with_tools) |> json.to_string()
}

/// Parse an OpenAI Chat Completions JSON response into an InferenceResult.
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
        error.InvalidResponse("Missing or invalid 'choices' field")
    }
  })
}

// ─── Internal: JSON building ───────────────────────────────────

fn message_to_json(msg: Message) -> json.Json {
  case msg {
    message.User(content:) ->
      json.object([
        #("role", json.string("user")),
        #("content", json.string(content)),
      ])

    message.System(content:) ->
      json.object([
        #("role", json.string("system")),
        #("content", json.string(content)),
      ])

    message.Assistant(content:, tool_calls:, thinking:, stop_reason: _) ->
      assistant_to_json(content, tool_calls, thinking)

    message.Tool(tool_call_id:, content:) ->
      json.object([
        #("role", json.string("tool")),
        #("tool_call_id", json.string(tool_call_id)),
        #("content", json.string(content)),
      ])
  }
}

fn assistant_to_json(
  content: String,
  tool_calls: List(message.ToolCall),
  _thinking: Option(message.Thinking),
) -> json.Json {
  let base = [
    #("role", json.string("assistant")),
    #("content", json.string(content)),
  ]
  case tool_calls {
    [] -> json.object(base)
    tcs ->
      json.object(
        base
        |> list.append([#("tool_calls", json.array(tcs, tool_call_to_json))]),
      )
  }
}

fn tool_call_to_json(tc: message.ToolCall) -> json.Json {
  json.object([
    #("id", json.string(tc.id)),
    #("type", json.string("function")),
    #(
      "function",
      json.object([
        #("name", json.string(tc.name)),
        #("arguments", json.string(tc.arguments_json)),
      ]),
    ),
  ])
}

fn tool_to_json(td: ToolDefinition) -> json.Json {
  json.object([
    #("type", json.string("function")),
    #(
      "function",
      json.object([
        #("name", json.string(td.name)),
        #("description", json.string(td.description)),
        #("parameters", schema.to_json(td.parameters)),
      ]),
    ),
  ])
}

// ─── Internal: JSON parsing ────────────────────────────────────

fn response_decoder() -> decode.Decoder(InferenceResult) {
  // Decode metadata fields
  use response_id <- decode.field("id", decode.optional(decode.string))
  use response_model <- decode.field("model", decode.optional(decode.string))

  // Decode choices to get message and stop_reason
  use choices <- decode.field("choices", decode.list(choice_decoder()))
  case list.first(choices) {
    Ok(#(msg, sr)) -> {
      use usage <- decode.optional_field(
        "usage",
        None,
        decode.optional(usage_decoder()),
      )
      let metadata =
        InferenceMetadata(
          response_id: response_id,
          response_model: response_model,
          stop_reason: sr,
          input_tokens: option.map(usage, fn(u) { u.prompt_tokens }),
          output_tokens: option.map(usage, fn(u) { u.completion_tokens }),
        )
      decode.success(InferenceResult(message: msg, metadata:))
    }
    Error(Nil) ->
      decode.failure(
        InferenceResult(
          message: message.Assistant("", [], None, None),
          metadata: default_metadata(),
        ),
        "non-empty choices",
      )
  }
}

type Usage {
  Usage(prompt_tokens: Int, completion_tokens: Int, total_tokens: Int)
}

fn usage_decoder() -> decode.Decoder(Usage) {
  use prompt_tokens <- decode.field("prompt_tokens", decode.int)
  use completion_tokens <- decode.field("completion_tokens", decode.int)
  use total_tokens <- decode.field("total_tokens", decode.int)
  decode.success(Usage(prompt_tokens:, completion_tokens:, total_tokens:))
}

fn choice_decoder() -> decode.Decoder(
  #(Message, Option(stop_reason.StopReason)),
) {
  use raw_msg <- decode.field("message", message_decoder())
  use raw_finish_reason <- decode.optional_field(
    "finish_reason",
    None,
    decode.optional(decode.string),
  )
  let sr = option.map(raw_finish_reason, stop_reason.from_openai)
  // Stamp stop_reason onto the Assistant message
  let msg = case raw_msg {
    message.Assistant(content:, tool_calls:, thinking:, stop_reason: _) ->
      message.Assistant(content:, tool_calls:, thinking:, stop_reason: sr)
    other -> other
  }
  decode.success(#(msg, sr))
}

fn message_decoder() -> decode.Decoder(Message) {
  use content <- decode.optional_field(
    "content",
    None,
    decode.optional(decode.string),
  )
  use tool_calls <- decode.optional_field(
    "tool_calls",
    None,
    decode.optional(decode.list(tool_call_decoder())),
  )
  let content_str = option.unwrap(content, "")
  let tcs = option.unwrap(tool_calls, [])
  decode.success(message.Assistant(
    content: content_str,
    tool_calls: tcs,
    thinking: None,
    stop_reason: None,
  ))
}

fn tool_call_decoder() -> decode.Decoder(message.ToolCall) {
  use id <- decode.field("id", decode.string)
  use name <- decode.subfield(["function", "name"], decode.string)
  use args <- decode.subfield(["function", "arguments"], decode.string)
  decode.success(message.ToolCall(id:, name:, arguments_json: args))
}
