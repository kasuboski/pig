//// Centralized pure test harness for OpenAI provider request configuration.
////
//// Tests provide request data and inspect the resulting JSON without network
//// access. If the provider builder API changes, only this module needs updates.

import gleam/option.{type Option, None, Some}
import pig/openai
import pig/provider.{InferenceRequest}
import pig_protocol/message.{type Message}
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
  provider_default: Option(ThinkingLevel),
  request_level: Option(ThinkingLevel),
) -> String {
  let provider = case api {
    Chat -> openai.provider("sk-test", "gpt-5")
    Responses -> openai.responses_provider("sk-test", "gpt-5")
  }
  let provider = case provider_default {
    Some(level) -> openai.with_default_thinking_level(provider, level)
    None -> provider
  }
  let settings = case request_level {
    Some(level) -> provider.with_thinking_level(level)
    None -> provider.default_settings()
  }
  let request = InferenceRequest(messages:, tools: [], settings:)
  openai.build_provider_request_body(provider, request)
}
