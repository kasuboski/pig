//// Centralized pure test harness for OpenAI provider request configuration.
////
//// Tests provide request data and inspect the resulting JSON without network
//// access. If the provider builder API changes, only this module needs updates.

import gleam/option.{type Option, None, Some}
import pig/openai
import pig_protocol/message.{type Message, System}
import pig_protocol/thinking.{type ThinkingLevel}

/// The OpenAI request API exercised by a test case.
pub type OpenAIRequestApi {
  Chat
  Responses
}

/// Build a request, allowing the request setting to override the provider default.
pub fn check_request(
  api: OpenAIRequestApi,
  messages: List(Message),
  system_prompt: Option(String),
  provider_default: Option(ThinkingLevel),
  request_level: Option(ThinkingLevel),
) -> String {
  let thinking_level = case request_level {
    Some(level) -> Some(level)
    None -> provider_default
  }
  case api {
    Chat ->
      openai.build_request_body_with_thinking(
        chat_messages(messages, system_prompt),
        [],
        "gpt-5",
        thinking_level,
      )
    Responses ->
      openai.build_responses_request_body_with_thinking(
        messages,
        [],
        "gpt-5",
        system_prompt,
        thinking_level,
      )
  }
}

fn chat_messages(
  messages: List(Message),
  system_prompt: Option(String),
) -> List(Message) {
  case system_prompt {
    Some(prompt) -> [System(prompt), ..messages]
    None -> messages
  }
}
