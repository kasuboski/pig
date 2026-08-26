//// Centralized pure test harness for OpenAI provider request configuration.
////
//// Tests provide request data and inspect the resulting JSON without network
//// access. If the provider builder API changes, only this module needs updates.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import pig/openai
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
  let thinking_level = case request_level {
    Some(level) -> Some(level)
    None -> provider_default
  }
  let instructions =
    messages
    |> list.filter_map(fn(message) {
      case message {
        message.System(content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
    |> string.join("\n\n")
  case api {
    Chat ->
      openai.build_request_body_with_thinking(
        messages,
        [],
        "gpt-5",
        thinking_level,
      )
    Responses ->
      openai.build_responses_request_body_with_thinking(
        messages,
        [],
        "gpt-5",
        case instructions {
          "" -> None
          value -> Some(value)
        },
        thinking_level,
      )
  }
}
