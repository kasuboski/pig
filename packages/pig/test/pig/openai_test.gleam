//// Tests for the streaming OpenAI provider boundary and request construction.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleeunit
import pig/openai
import pig/provider
import pig_protocol/message
import pig_protocol/thinking
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
      [
        message.System("first instruction"),
        message.System("second instruction"),
        message.User("hello"),
      ],
      None,
      None,
    )
  let assert Ok("first instruction\n\nsecond instruction") =
    json.parse(body, decode.at(["instructions"], decode.string))
}

pub fn buffered_provider_has_no_delta_before_completion_test() {
  let response =
    provider.from_message(message.Assistant("done", [], None, None))
  let inference =
    provider.start(
      provider.from_buffered(fn(_) { Ok(response) }),
      provider.InferenceRequest(
        messages: [message.User("hello")],
        tools: [],
        settings: provider.default_settings(),
      ),
    )
  let assert Ok(provider.Finished(Ok(result))) =
    provider.receive(inference, 1000)
  assert result == response
}
