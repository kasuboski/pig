import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import jscheam/schema
import pig/ai/error
import pig/ai/message
import pig/ai/openai
import pig/ai/tool_definition
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// === Helper: read golden file ===

fn read_golden(path: String) -> String {
  let assert Ok(content) = simplifile.read(path)
  content
}

// === Helpers: decode build_request_body JSON ===

/// Check if a top-level key exists in the JSON body.
fn body_has_key(body: String, key: String) -> Bool {
  let decoder = decode.at([key], decode.optional(decode.dynamic))
  case json.parse(from: body, using: decoder) {
    Ok(Some(_)) -> True
    _ -> False
  }
}

/// A decoded message entry from build_request_body JSON.
type MsgEntry {
  MsgEntry(role: String, content: String)
}

fn msg_entry_decoder() -> decode.Decoder(MsgEntry) {
  use role <- decode.field("role", decode.string)
  use content <- decode.field("content", decode.optional(decode.string))
  decode.success(MsgEntry(role:, content: option.unwrap(content, "")))
}

fn decode_messages(body: String) -> List(#(String, String)) {
  let decoder = {
    use msgs <- decode.field("messages", decode.list(msg_entry_decoder()))
    decode.success(msgs)
  }
  let assert Ok(msgs) =
    json.parse(from: body, using: decoder)
    |> result.map_error(fn(_) { Nil })
  list.map(msgs, fn(m: MsgEntry) { #(m.role, m.content) })
}

fn decode_tool_names(body: String) -> Result(List(String), Nil) {
  let decoder = {
    use name <- decode.subfield(["function", "name"], decode.string)
    decode.success(name)
  }
  let decoder = {
    use names <- decode.field("tools", decode.list(decoder))
    decode.success(names)
  }
  json.parse(from: body, using: decoder)
  |> result.map_error(fn(_) { Nil })
}

// === parse_response golden file tests ===

pub fn parse_text_response_test() {
  let raw = read_golden("./test_data/providers/openai_text_response.json")
  let assert Ok(result) = openai.parse_response(raw)
  let assert message.Assistant(
    content: "The answer is 4.",
    tool_calls: [],
    thinking: None,
  ) = result.message
  // Verify metadata
  let assert Some("chatcmpl-abc123") = result.metadata.response_id
  let assert Some("gpt-4o") = result.metadata.response_model
  let assert Some("stop") = result.metadata.finish_reason
  let assert Some(25) = result.metadata.input_tokens
  let assert Some(6) = result.metadata.output_tokens
}

pub fn parse_tool_call_response_test() {
  let raw = read_golden("./test_data/providers/openai_tool_call_response.json")
  let assert Ok(result) = openai.parse_response(raw)
  let assert message.Assistant(content: "", tool_calls: [tc], thinking: None) =
    result.message
  let assert True =
    tc.id == "call_abc123"
    && tc.name == "calculator"
    && tc.arguments_json == "{\"expression\": \"2+2\"}"
  // Verify metadata
  let assert Some("chatcmpl-def456") = result.metadata.response_id
  let assert Some("gpt-4o") = result.metadata.response_model
  let assert Some("tool_calls") = result.metadata.finish_reason
  let assert Some(30) = result.metadata.input_tokens
  let assert Some(15) = result.metadata.output_tokens
}

pub fn parse_multi_tool_call_response_test() {
  let raw =
    read_golden("./test_data/providers/openai_multi_tool_call_response.json")
  let assert Ok(result) = openai.parse_response(raw)
  let assert message.Assistant(
    content: "",
    tool_calls: [tc1, tc2, tc3],
    thinking: None,
  ) = result.message
  let assert True =
    tc1.id == "call_001"
    && tc1.name == "get_weather"
    && tc2.id == "call_002"
    && tc2.name == "get_weather"
    && tc3.id == "call_003"
    && tc3.name == "calculator"
  // Verify metadata
  let assert Some("chatcmpl-ghi789") = result.metadata.response_id
  let assert Some("gpt-4o") = result.metadata.response_model
  let assert Some("tool_calls") = result.metadata.finish_reason
  let assert Some(40) = result.metadata.input_tokens
  let assert Some(30) = result.metadata.output_tokens
}

pub fn parse_null_content_response_test() {
  let raw =
    read_golden("./test_data/providers/openai_null_content_response.json")
  let assert Ok(result) = openai.parse_response(raw)
  let assert message.Assistant(content: "", tool_calls: [], thinking: None) =
    result.message
  // Verify metadata
  let assert Some("chatcmpl-jkl012") = result.metadata.response_id
  let assert Some("gpt-4o") = result.metadata.response_model
  let assert Some("stop") = result.metadata.finish_reason
  let assert Some(10) = result.metadata.input_tokens
  let assert Some(0) = result.metadata.output_tokens
}

// === parse_response metadata tests ===

pub fn parse_response_captures_response_id_test() {
  let raw = read_golden("./test_data/providers/openai_text_response.json")
  let assert Ok(result) = openai.parse_response(raw)
  let assert Some("chatcmpl-abc123") = result.metadata.response_id
}

pub fn parse_response_captures_response_model_test() {
  let raw = read_golden("./test_data/providers/openai_text_response.json")
  let assert Ok(result) = openai.parse_response(raw)
  let assert Some("gpt-4o") = result.metadata.response_model
}

pub fn parse_response_captures_finish_reason_test() {
  let raw = read_golden("./test_data/providers/openai_text_response.json")
  let assert Ok(result) = openai.parse_response(raw)
  let assert Some("stop") = result.metadata.finish_reason
}

pub fn parse_response_captures_token_usage_test() {
  let raw = read_golden("./test_data/providers/openai_text_response.json")
  let assert Ok(result) = openai.parse_response(raw)
  let assert Some(25) = result.metadata.input_tokens
  let assert Some(6) = result.metadata.output_tokens
}

// === parse_response error cases (inline) ===

pub fn parse_malformed_json_returns_invalid_response_test() {
  let result = openai.parse_response("not json at all")
  let assert Error(error.InvalidResponse(detail:)) = result
  assert string.contains(detail, "JSON")
}

pub fn parse_missing_choices_returns_invalid_response_test() {
  let result =
    openai.parse_response("{\"id\":\"x\",\"object\":\"chat.completion\"}")
  let assert Error(error.InvalidResponse(detail:)) = result
  assert string.contains(detail, "choices")
}

pub fn parse_empty_choices_returns_invalid_response_test() {
  let result = openai.parse_response("{\"choices\":[]}")
  let assert Error(error.InvalidResponse(detail: _)) = result
}

// === build_request_body tests ===

pub fn build_request_body_simple_messages_test() {
  let messages = [
    message.System("you are helpful"),
    message.User("hello"),
  ]
  let body = openai.build_request_body(messages, [], "gpt-4o")

  let model_dec = {
    use m <- decode.field("model", decode.string)
    decode.success(m)
  }
  let assert Ok("gpt-4o") =
    json.parse(from: body, using: model_dec)
    |> result.map_error(fn(_) { Nil })
  let stream_dec = {
    use s <- decode.field("stream", decode.bool)
    decode.success(s)
  }
  let assert Ok(False) =
    json.parse(from: body, using: stream_dec)
    |> result.map_error(fn(_) { Nil })
  let parsed = decode_messages(body)
  let assert True =
    parsed == [#("system", "you are helpful"), #("user", "hello")]
}

pub fn build_request_body_with_tools_test() {
  let messages = [message.User("what is 2+2?")]
  let tools = [
    tool_definition.ToolDefinition(
      name: "calculator",
      description: "evaluates math",
      parameters: schema.object([
        schema.prop("expression", schema.string())
        |> schema.description("Math expression to evaluate"),
      ]),
    ),
  ]
  let body = openai.build_request_body(messages, tools, "gpt-4o")

  let assert Ok(names) = decode_tool_names(body)
  assert names == ["calculator"]
}

pub fn build_request_body_with_assistant_tool_calls_test() {
  let tc =
    message.ToolCall(
      id: "call_123",
      name: "calculator",
      arguments_json: "{\"expression\":\"2+2\"}",
    )
  let messages = [
    message.User("what is 2+2?"),
    message.Assistant("", [tc], None),
    message.Tool(tool_call_id: "call_123", content: "4"),
  ]
  let body = openai.build_request_body(messages, [], "gpt-4o")

  // No top-level "tools" — tool calls are in the messages array
  let assert True =
    body_has_key(body, "tools") == False
    && body_has_key(body, "messages")
    && string.contains(body, "tool_calls")
    && string.contains(body, "tool_call_id")
}

pub fn build_request_body_no_tools_field_when_empty_test() {
  let messages = [message.User("hello")]
  let body = openai.build_request_body(messages, [], "gpt-4o")

  assert body_has_key(body, "tools") == False
}

pub fn build_request_body_tool_parameters_injected_as_json_test() {
  let messages = [message.User("go")]
  let tools = [
    tool_definition.ToolDefinition(
      name: "search",
      description: "search the web",
      parameters: schema.object([]),
    ),
  ]
  let body = openai.build_request_body(messages, tools, "gpt-4o")

  // Decode parameters as a dict — proves it's a JSON object, not a string
  let decoder = {
    use _params <- decode.subfield(
      ["function", "parameters"],
      decode.dict(decode.string, decode.dynamic),
    )
    decode.success(True)
  }
  let decoder = {
    use _tools <- decode.field("tools", decode.list(decoder))
    decode.success(True)
  }
  let assert True = json.parse(from: body, using: decoder) == Ok(True)
}

// === provider construction tests ===

pub fn provider_with_default_base_url_test() {
  let openai.OpenAIProvider(config:, call: _) =
    openai.provider("sk-test", "gpt-4o")
  let assert True =
    config.base_url == "https://api.openai.com/v1"
    && config.api_key == "sk-test"
    && config.model == "gpt-4o"
}

pub fn provider_with_custom_base_url_test() {
  let openai.OpenAIProvider(config:, call: _) =
    openai.provider_with_base_url(
      "key",
      "qwen3:0.6b",
      "http://localhost:11434/v1",
    )
  let assert True =
    config.base_url == "http://localhost:11434/v1"
    && config.model == "qwen3:0.6b"
}
