import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleeunit
import pig/openai
import pig_protocol/message
import pig_protocol/thinking
import support/openai_harness

pub fn main() -> Nil {
  gleeunit.main()
}

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

pub fn provider_with_base_url_and_timeout_test() {
  let openai.OpenAIProvider(config:, call: _) =
    openai.provider_with_base_url_and_timeout(
      "sk-test",
      "gpt-4o",
      "http://localhost:11434/v1",
      30_000,
    )
  let assert True =
    config.api_key == "sk-test"
    && config.model == "gpt-4o"
    && config.base_url == "http://localhost:11434/v1"
    && config.http_timeout_ms == 30_000
}

pub fn with_http_timeout_overrides_test() {
  let original =
    openai.provider_with_base_url(
      "sk-test",
      "gpt-4o",
      "http://localhost:11434/v1",
    )
  let openai.OpenAIProvider(config: updated, call: _) =
    openai.with_http_timeout(original, 5000)
  let assert True =
    updated.api_key == "sk-test"
    && updated.model == "gpt-4o"
    && updated.base_url == "http://localhost:11434/v1"
    && updated.http_timeout_ms == 5000
}

pub fn configured_provider_builds_request_with_thinking_test() {
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

pub fn responses_provider_builds_request_with_thinking_test() {
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
