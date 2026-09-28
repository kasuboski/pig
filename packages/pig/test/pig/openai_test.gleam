//// Tests for the streaming OpenAI provider boundary and request construction.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{type Option, None, Some}
import gleeunit
import pig/openai
import pig/provider
import pig_protocol/message
import pig_protocol/thinking
import pig_transport
import support/openai_harness

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn provider_builders_are_streaming_first_test() {
  let chat = openai.build_request_body([message.User("hello")], [], "gpt-4o")
  let assert Ok(True) = json.parse(chat, decode.at(["stream"], decode.bool))
  let responses =
    openai.build_responses_request_body(
      [message.User("hello")],
      [],
      "gpt-5",
      None,
    )
  let assert Ok(True) =
    json.parse(responses, decode.at(["stream"], decode.bool))
}

pub fn configured_provider_builds_chat_request_with_thinking_test() {
  let body =
    openai_harness.check_request(
      openai_harness.Chat,
      [message.User("solve this")],
      None,
      None,
      Some(thinking.Medium),
    )
  let assert Ok("medium") =
    json.parse(body, decode.at(["reasoning_effort"], decode.string))
}

pub fn configured_provider_builds_responses_request_with_thinking_test() {
  let body =
    openai_harness.check_request(
      openai_harness.Responses,
      [message.User("solve this")],
      None,
      None,
      Some(thinking.High),
    )
  let assert Ok("high") =
    json.parse(body, decode.at(["reasoning", "effort"], decode.string))
}

pub fn provider_default_is_used_when_request_defers_test() {
  let body =
    openai_harness.check_request(
      openai_harness.Chat,
      [message.User("solve this")],
      None,
      Some(thinking.High),
      None,
    )
  let assert Ok("high") =
    json.parse(body, decode.at(["reasoning_effort"], decode.string))
}

pub fn request_level_overrides_provider_default_for_responses_test() {
  let body =
    openai_harness.check_request(
      openai_harness.Responses,
      [message.User("solve this")],
      None,
      Some(thinking.High),
      Some(thinking.Off),
    )
  let assert Ok("none") =
    json.parse(body, decode.at(["reasoning", "effort"], decode.string))
}

pub fn responses_provider_maps_system_messages_to_instructions_test() {
  let body =
    openai_harness.check_request(
      openai_harness.Responses,
      [message.User("hello")],
      Some("first instruction\n\nsecond instruction"),
      None,
      None,
    )
  let assert Ok("first instruction\n\nsecond instruction") =
    json.parse(body, decode.at(["instructions"], decode.string))
}

pub fn configured_adapters_send_guidance_and_replayed_turns_for_both_apis_test() {
  let turns = [
    message.User("question"),
    message.Assistant(
      "working",
      [message.ToolCall("call-1", "lookup", "{}")],
      None,
      None,
    ),
    message.Tool("call-1", "tool result"),
    message.Developer("turn guidance"),
  ]
  let role_decoder = decode.at(["role"], decode.string)
  let chat =
    check_outbound(openai.ChatCompletions, Some("standing guidance"), turns)
  let assert Ok(["system", "user", "assistant", "tool", "developer"]) =
    json.parse(chat, decode.at(["messages"], decode.list(role_decoder)))
  let assert Ok(["standing guidance", _, _, _, "turn guidance"]) =
    json.parse(
      chat,
      decode.at(
        ["messages"],
        decode.list(decode.at(["content"], decode.string)),
      ),
    )

  let responses =
    check_outbound(openai.Responses, Some("standing guidance"), turns)
  let assert Ok("standing guidance") =
    json.parse(responses, decode.at(["instructions"], decode.string))
  let input_role_decoder = {
    use role <- decode.optional_field("role", "tool", decode.string)
    decode.success(role)
  }
  let assert Ok(["user", "assistant", "tool", "tool", "developer"]) =
    json.parse(responses, decode.at(["input"], decode.list(input_role_decoder)))
}

/// Replay a Developer turn in place after later assistant/tool progress and a
/// fresh User turn. The tool output must still follow its matching call.
pub fn configured_adapters_replay_developer_on_subsequent_turn_test() {
  let turns = [
    message.User("first question"),
    message.Assistant("first answer", [], None, None),
    message.Developer("updated constraints"),
    message.Assistant(
      "checking",
      [message.ToolCall("call-2", "lookup", "{}")],
      None,
      None,
    ),
    message.Tool("call-2", "found it"),
    message.User("follow up"),
  ]
  let chat =
    check_outbound(openai.ChatCompletions, Some("standing guidance"), turns)
  let assert Ok([
    "system",
    "user",
    "assistant",
    "developer",
    "assistant",
    "tool",
    "user",
  ]) =
    json.parse(
      chat,
      decode.at(["messages"], decode.list(decode.at(["role"], decode.string))),
    )
  let chat_item_decoder = {
    use content <- decode.optional_field("content", "", decode.string)
    use call_id <- decode.optional_field("tool_call_id", "", decode.string)
    use tool_calls <- decode.optional_field(
      "tool_calls",
      [],
      decode.list(decode.at(["id"], decode.string)),
    )
    decode.success(#(content, call_id, tool_calls))
  }
  let assert Ok([
    _,
    _,
    _,
    #("updated constraints", "", []),
    #(_, "", ["call-2"]),
    #("found it", "call-2", []),
    _,
  ]) = json.parse(chat, decode.at(["messages"], decode.list(chat_item_decoder)))

  let responses =
    check_outbound(openai.Responses, Some("standing guidance"), turns)
  let assert Ok("standing guidance") =
    json.parse(responses, decode.at(["instructions"], decode.string))
  let responses_item_decoder = {
    use item_type <- decode.field("type", decode.string)
    use role <- decode.optional_field("role", "", decode.string)
    use call_id <- decode.optional_field("call_id", "", decode.string)
    use content <- decode.optional_field(
      "content",
      [],
      decode.list(decode.at(["text"], decode.string)),
    )
    decode.success(#(item_type, role, call_id, content))
  }
  let assert Ok([
    #("message", "user", "", _),
    #("message", "assistant", "", _),
    #("message", "developer", "", ["updated constraints"]),
    #("message", "assistant", "", _),
    #("function_call", "", "call-2", []),
    #("function_call_output", "", "call-2", []),
    #("message", "user", "", ["follow up"]),
  ]) =
    json.parse(
      responses,
      decode.at(["input"], decode.list(responses_item_decoder)),
    )
}

pub fn configured_adapters_omit_absent_guidance_test() {
  let chat =
    check_outbound(openai.ChatCompletions, None, [
      message.User("question"),
      message.Developer("same text"),
    ])
  let assert Ok(["user", "developer"]) =
    json.parse(
      chat,
      decode.at(["messages"], decode.list(decode.at(["role"], decode.string))),
    )
  let responses =
    check_outbound(openai.Responses, None, [
      message.User("question"),
      message.Developer("same text"),
    ])
  let assert Error(_) =
    json.parse(responses, decode.at(["instructions"], decode.string))
  let assert Ok(["user", "developer"]) =
    json.parse(
      responses,
      decode.at(["input"], decode.list(decode.at(["role"], decode.string))),
    )
}

pub fn developer_matching_standing_guidance_remains_a_turn_test() {
  let turns = [message.Developer("same text")]
  let chat = check_outbound(openai.ChatCompletions, Some("same text"), turns)
  let assert Ok(["system", "developer"]) =
    json.parse(
      chat,
      decode.at(["messages"], decode.list(decode.at(["role"], decode.string))),
    )
  let responses = check_outbound(openai.Responses, Some("same text"), turns)
  let assert Ok("same text") =
    json.parse(responses, decode.at(["instructions"], decode.string))
  let assert Ok(["developer"]) =
    json.parse(
      responses,
      decode.at(["input"], decode.list(decode.at(["role"], decode.string))),
    )
}

fn check_outbound(
  api: openai.OpenAIApi,
  system_prompt: Option(String),
  messages: List(message.Message),
) -> String {
  let seen = process.new_subject()
  let body = case api {
    openai.ChatCompletions ->
      "data: {\"id\":\"chat-1\",\"model\":\"gpt-5\",\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\n"
      <> "data: [DONE]\n\n"
    openai.Responses ->
      "data: {\"type\":\"response.created\",\"response\":{\"id\":\"r1\",\"model\":\"gpt-5\"}}\n\n"
      <> "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}}\n\n"
      <> "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"ok\"}\n\n"
      <> "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"model\":\"gpt-5\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}\n\n"
  }
  let prov =
    openai.provider_with_transport(
      api,
      "key",
      "gpt-5",
      "http://example.test/v1",
      1000,
      pig_transport.Transport(
        sync: fn(_) { pig_transport.TransportError("unused") },
        stream: fn(request, events) {
          process.send(seen, request.body)
          process.send(events, pig_transport.SourceHead(200, []))
          process.send(
            events,
            pig_transport.SourceChunk(bit_array.from_string(body)),
          )
          process.send(events, pig_transport.SourceDone)
        },
      ),
    )
  let inference =
    provider.start(
      prov,
      provider.InferenceRequest(
        system_prompt:,
        messages:,
        tools: [],
        settings: provider.default_settings(),
      ),
    )
  let assert Ok(request_body) = process.receive(seen, 1000)
  let _ = provider.collect(inference, 1000)
  request_body
}

pub fn system_guidance_and_replayed_turns_are_encoded_for_both_apis_test() {
  let turns = [
    message.User("question"),
    message.Assistant(
      "working",
      [message.ToolCall("call-1", "lookup", "{}")],
      None,
      None,
    ),
    message.Tool("call-1", "tool result"),
    message.Developer("remember this"),
  ]
  let chat =
    openai_harness.check_request(
      openai_harness.Chat,
      turns,
      Some("standing guidance"),
      None,
      None,
    )
  let role_decoder = decode.at(["role"], decode.string)
  let assert Ok(["system", "user", "assistant", "tool", "developer"]) =
    json.parse(chat, decode.at(["messages"], decode.list(role_decoder)))
  let responses =
    openai_harness.check_request(
      openai_harness.Responses,
      turns,
      Some("standing guidance"),
      None,
      None,
    )
  let assert Ok("standing guidance") =
    json.parse(responses, decode.at(["instructions"], decode.string))
}

pub fn buffered_provider_has_no_delta_before_completion_test() {
  let response =
    provider.from_message(message.Assistant("done", [], None, None))
  let inference =
    provider.start(
      provider.from_buffered(fn(_) { Ok(response) }),
      provider.InferenceRequest(
        system_prompt: None,
        messages: [message.User("hello")],
        tools: [],
        settings: provider.default_settings(),
      ),
    )
  let assert Ok(provider.Finished(Ok(result))) =
    provider.receive(inference, 1000)
  assert result == response
}
