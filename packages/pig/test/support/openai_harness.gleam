//// Centralized pure test harness for OpenAI provider request configuration.
////
//// Tests provide request data and inspect the resulting JSON without network
//// access. If the provider builder API changes, only this module needs updates.

import gleam/option.{type Option, None, Some}
import pig/openai
import pig_protocol/message.{type Message}
import pig_protocol/thinking.{type ThinkingLevel}

/// The OpenAI request API exercised by a test case.
pub type Api {
  Chat
  Responses
}

/// Build the request produced by a configured OpenAI provider.
pub fn check_request(
  api: Api,
  messages: List(Message),
  thinking_level: Option(ThinkingLevel),
) -> String {
  let provider = case api {
    Chat -> openai.provider("sk-test", "gpt-5")
    Responses -> openai.responses_provider("sk-test", "gpt-5")
  }
  let provider = case thinking_level {
    Some(level) -> openai.with_thinking_level(provider, level)
    None -> provider
  }
  openai.build_provider_request_body(provider, messages, [])
}
