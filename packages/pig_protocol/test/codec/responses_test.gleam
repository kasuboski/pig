import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import jscheam/schema
import pig_protocol/codec/responses
import pig_protocol/message
import pig_protocol/stop_reason
import pig_protocol/thinking
import pig_protocol/tool_definition
import support/json_assertions

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Build request ─────────────────────────────────────────────────

pub fn build_request_body_simple_messages_test() {
  let messages = [
    message.System("you are helpful"),
    message.User("hello"),
  ]
  let body = responses.build_request_body(messages, [], "gpt-4o", None)

  let assert Ok("gpt-4o") =
    json.parse(body, decode.at(["model"], decode.string))
  let assert Ok(False) = json.parse(body, decode.at(["store"], decode.bool))
  let assert Ok(False) = json.parse(body, decode.at(["stream"], decode.bool))
  let assert Ok("auto") =
    json.parse(body, decode.at(["tool_choice"], decode.string))
  let assert Ok(True) =
    json.parse(body, decode.at(["parallel_tool_calls"], decode.bool))
  assert json_assertions.omits_path(body, ["reasoning"])
}

pub fn build_request_body_system_ignored_when_instructions_missing_test() {
  let messages = [
    message.System("system prompt"),
    message.User("hello"),
  ]
  let body = responses.build_request_body(messages, [], "gpt-4o", None)

  // System messages are omitted from input; instructions is also absent here
  let assert Ok(input) =
    json.parse(body, decode.at(["input"], decode.list(decode.dynamic)))
  assert list.length(input) == 1
}

pub fn build_request_body_instructions_added_test() {
  let body = responses.build_request_body([], [], "gpt-4o", Some("be helpful"))
  let assert Ok("be helpful") =
    json.parse(body, decode.at(["instructions"], decode.string))
}

pub fn build_request_body_with_thinking_level_test() {
  let body =
    responses.build_request_body_with_thinking(
      [message.User("solve this")],
      [],
      "gpt-5",
      None,
      Some(thinking.Medium),
    )

  let assert Ok(#("medium", "auto")) =
    json.parse(body, {
      use effort <- decode.subfield(["reasoning", "effort"], decode.string)
      use summary <- decode.subfield(["reasoning", "summary"], decode.string)
      decode.success(#(effort, summary))
    })
}

pub fn build_request_body_with_thinking_off_test() {
  let body =
    responses.build_request_body_with_thinking(
      [message.User("answer directly")],
      [],
      "gpt-5",
      None,
      Some(thinking.Off),
    )

  let assert Ok("none") =
    json.parse(body, decode.at(["reasoning", "effort"], decode.string))
  assert json_assertions.omits_path(body, ["reasoning", "summary"])
}

pub fn build_request_body_with_tools_test() {
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
  let body =
    responses.build_request_body(
      [message.User("what is 2+2?")],
      tools,
      "gpt-4o",
      None,
    )

  let decoder = {
    use name <- decode.subfield(["name"], decode.string)
    decode.success(name)
  }
  let decoder = {
    use names <- decode.field("tools", decode.list(decoder))
    decode.success(names)
  }
  let assert Ok(names) = json.parse(body, decoder)
  assert names == ["calculator"]
}

pub fn build_request_body_tool_message_as_function_call_output_test() {
  let messages = [
    message.User("what is 2+2?"),
    message.Assistant(
      "",
      [
        message.ToolCall(
          id: "call_123",
          name: "calculator",
          arguments_json: "{}",
        ),
      ],
      None,
      None,
    ),
    message.Tool(tool_call_id: "call_123", content: "4"),
  ]
  let body = responses.build_request_body(messages, [], "gpt-4o", None)

  // Protocol quirk: an assistant with tool calls but no text emits only a
  // `function_call` item (no `message`), and each `function_call_output`
  // must be preceded by a `function_call` sharing the same `call_id`.
  let items = input_items(body)
  assert items
    == [
      #("message", None),
      #("function_call", Some("call_123")),
      #("function_call_output", Some("call_123")),
    ]
}

pub fn build_request_body_assistant_with_text_and_tool_calls_test() {
  let messages = [
    message.User("weather?"),
    message.Assistant(
      "let me check",
      [
        message.ToolCall(
          id: "call_9",
          name: "get_weather",
          arguments_json: "{}",
        ),
      ],
      None,
      None,
    ),
  ]
  let body = responses.build_request_body(messages, [], "gpt-4o", None)

  // Protocol quirk: assistant text and tool calls are emitted as separate
  // input items — an `output_text` message followed by a `function_call`.
  let items = input_items(body)
  assert items
    == [
      #("message", None),
      #("message", None),
      #("function_call", Some("call_9")),
    ]
}

// ── Parse response ────────────────────────────────────────────────

pub fn parse_text_response_test() {
  let raw = sample_text_response()
  let assert Ok(result) = responses.parse_response(raw)
  let assert message.Assistant(
    content: "Refactored code complete.",
    tool_calls: [],
    thinking: None,
    stop_reason: Some(stop_reason.Stop),
  ) = result.message
  let assert Some("resp-01") = result.metadata.response_id
  let assert Some("gpt-5.3-codex") = result.metadata.response_model
  let assert Some(stop_reason.Stop) = result.metadata.stop_reason
  let assert Some(15) = result.metadata.input_tokens
  let assert Some(30) = result.metadata.output_tokens
  let assert Some(12) = result.metadata.cached_input_tokens
}

pub fn parse_tool_call_response_test() {
  let raw = sample_tool_call_response()
  let assert Ok(result) = responses.parse_response(raw)
  let assert message.Assistant(
    content: "",
    tool_calls: [tc],
    thinking: None,
    stop_reason: Some(stop_reason.ToolUse),
  ) = result.message
  // Protocol quirk: the parsed tool-call id must be `call_id` (call_001),
  // not the item `id` (fc_abc123), so tool results round-trip correctly.
  assert tc.id == "call_001"
  assert tc.name == "get_weather"
  assert tc.arguments_json == "{\"location\":\"Berlin\"}"
  let assert Some(stop_reason.ToolUse) = result.metadata.stop_reason
}

pub fn parse_incomplete_response_test() {
  let raw = sample_incomplete_response()
  let assert Ok(result) = responses.parse_response(raw)
  let assert message.Assistant(
    content: "",
    tool_calls: [],
    thinking: None,
    stop_reason: Some(stop_reason.Length),
  ) = result.message
  let assert Some(stop_reason.Length) = result.metadata.stop_reason
}

// ── Helpers ─────────────────────────────────────────────────────

fn input_items(body: String) -> List(#(String, option.Option(String))) {
  let item_decoder = {
    use item_type <- decode.field("type", decode.string)
    use call_id <- decode.optional_field(
      "call_id",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(item_type, call_id))
  }
  let assert Ok(items) =
    json.parse(body, decode.at(["input"], decode.list(item_decoder)))
  items
}

fn sample_text_response() -> String {
  "{
    \"id\": \"resp-01\",
    \"object\": \"response\",
    \"status\": \"completed\",
    \"model\": \"gpt-5.3-codex\",
    \"output\": [
      {
        \"type\": \"message\",
        \"role\": \"assistant\",
        \"content\": [
          { \"type\": \"output_text\", \"text\": \"Refactored code complete.\" }
        ],
        \"status\": \"completed\"
      }
    ],
    \"usage\": { \"input_tokens\": 15, \"output_tokens\": 30, \"total_tokens\": 45, \"input_tokens_details\": { \"cached_tokens\": 12 } }
  }"
}

fn sample_tool_call_response() -> String {
  "{
    \"id\": \"resp-02\",
    \"object\": \"response\",
    \"status\": \"completed\",
    \"model\": \"gpt-5.3-codex\",
    \"output\": [
      {
        \"type\": \"function_call\",
        \"id\": \"fc_abc123\",
        \"call_id\": \"call_001\",
        \"name\": \"get_weather\",
        \"arguments\": \"{\\\"location\\\":\\\"Berlin\\\"}\"
      }
    ],
    \"usage\": { \"input_tokens\": 10, \"output_tokens\": 5, \"total_tokens\": 15 }
  }"
}

fn sample_incomplete_response() -> String {
  "{
    \"id\": \"resp-03\",
    \"object\": \"response\",
    \"status\": \"incomplete\",
    \"model\": \"gpt-5.3-codex\",
    \"output\": [],
    \"usage\": { \"input_tokens\": 8, \"output_tokens\": 0, \"total_tokens\": 8 }
  }"
}
