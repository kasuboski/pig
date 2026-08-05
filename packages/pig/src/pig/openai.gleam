import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pig/provider.{
  type InferenceRequest, type InferenceResult, type Provider, UseProviderDefault,
  UseThinkingLevel,
}
import pig_protocol/auth
import pig_protocol/codec/chat
import pig_protocol/codec/responses
import pig_protocol/error.{type AiError}
import pig_protocol/message.{type Message}
import pig_protocol/thinking.{type ThinkingLevel}
import pig_protocol/tool_definition.{type ToolDefinition}
import pig_protocol/transport.{HttpRequest}
import pig_protocol/transport/httpc

/// The OpenAI API used for inference.
pub type OpenAIApi {
  ChatCompletions
  Responses
}

/// Configuration for an OpenAI-compatible provider.
pub type OpenAIConfig {
  OpenAIConfig(
    api: OpenAIApi,
    api_key: String,
    model: String,
    base_url: String,
    http_timeout_ms: Int,
    default_thinking_level: Option(ThinkingLevel),
  )
}

/// An OpenAI-compatible provider wrapping a callable function with its config.
pub type OpenAIProvider {
  OpenAIProvider(config: OpenAIConfig, call: Provider)
}

/// The default OpenAI base URL.
pub const default_base_url = "https://api.openai.com/v1"

/// The default HTTP timeout for OpenAI API calls (120 seconds).
pub const default_http_timeout_ms = 120_000

/// Create a provider with the default OpenAI base URL.
pub fn provider(api_key: String, model: String) -> OpenAIProvider {
  provider_with_base_url(api_key, model, default_base_url)
}

/// Create a provider with a custom base URL (for Ollama, Together, etc).
pub fn provider_with_base_url(
  api_key: String,
  model: String,
  base_url: String,
) -> OpenAIProvider {
  provider_with_base_url_and_timeout(
    api_key,
    model,
    base_url,
    default_http_timeout_ms,
  )
}

/// Create a provider with a custom base URL and HTTP timeout.
pub fn provider_with_base_url_and_timeout(
  api_key: String,
  model: String,
  base_url: String,
  http_timeout_ms: Int,
) -> OpenAIProvider {
  provider_for_api(ChatCompletions, api_key, model, base_url, http_timeout_ms)
}

/// Create a Responses API provider with the default OpenAI base URL.
pub fn responses_provider(api_key: String, model: String) -> OpenAIProvider {
  responses_provider_with_base_url(api_key, model, default_base_url)
}

/// Create a Responses API provider with a custom base URL.
pub fn responses_provider_with_base_url(
  api_key: String,
  model: String,
  base_url: String,
) -> OpenAIProvider {
  responses_provider_with_base_url_and_timeout(
    api_key,
    model,
    base_url,
    default_http_timeout_ms,
  )
}

/// Create a Responses API provider with a custom base URL and HTTP timeout.
pub fn responses_provider_with_base_url_and_timeout(
  api_key: String,
  model: String,
  base_url: String,
  http_timeout_ms: Int,
) -> OpenAIProvider {
  provider_for_api(Responses, api_key, model, base_url, http_timeout_ms)
}

fn provider_for_api(
  api: OpenAIApi,
  api_key: String,
  model: String,
  base_url: String,
  http_timeout_ms: Int,
) -> OpenAIProvider {
  build_provider(OpenAIConfig(
    api:,
    api_key:,
    model:,
    base_url:,
    http_timeout_ms:,
    default_thinking_level: None,
  ))
}

/// Set the HTTP timeout in milliseconds on an OpenAI provider.
pub fn with_http_timeout(
  provider: OpenAIProvider,
  timeout_ms: Int,
) -> OpenAIProvider {
  build_provider(OpenAIConfig(..provider.config, http_timeout_ms: timeout_ms))
}

/// Set the fallback thinking level for calls made by this provider.
///
/// A request-level setting overrides this default. Chat Completions sends the
/// resolved level as `reasoning_effort`; Responses sends it as
/// `reasoning.effort`. Unsupported levels are returned as provider API errors.
pub fn with_default_thinking_level(
  provider: OpenAIProvider,
  level: ThinkingLevel,
) -> OpenAIProvider {
  build_provider(
    OpenAIConfig(..provider.config, default_thinking_level: Some(level)),
  )
}

/// Wrap an `OpenAIConfig` in an `OpenAIProvider` whose `call` closure
/// invokes `do_inference` with that config.
fn build_provider(config: OpenAIConfig) -> OpenAIProvider {
  OpenAIProvider(config: config, call: fn(request: InferenceRequest) -> Result(
    InferenceResult,
    AiError,
  ) {
    do_inference(config, request)
  })
}

/// Build the JSON request body for the OpenAI Chat Completions API.
/// Pure function — no IO.
pub fn build_request_body(
  messages: List(Message),
  tools: List(ToolDefinition),
  model: String,
) -> String {
  chat.build_request_body(messages, tools, model)
}

/// Build the JSON request body that a configured provider will send.
/// Pure function — useful for inspecting provider configuration without IO.
pub fn build_provider_request_body(
  provider: OpenAIProvider,
  request: InferenceRequest,
) -> String {
  request_body(provider.config, request)
}

/// Parse an OpenAI Chat Completions JSON response into an InferenceResult.
/// Pure function — no IO.
pub fn parse_response(raw: String) -> Result(InferenceResult, AiError) {
  chat.parse_response(raw)
}

// ─── Internal: inference ───────────────────────────────────────

fn do_inference(
  config: OpenAIConfig,
  request: InferenceRequest,
) -> Result(InferenceResult, AiError) {
  let mode = auth.StandardApi(config.api_key, config.base_url)
  let #(url, body, parse) = case config.api {
    ChatCompletions -> #(
      auth.chat_url(mode),
      request_body(config, request),
      chat.parse_response,
    )
    Responses -> #(
      auth.responses_url(mode),
      request_body(config, request),
      responses.parse_response,
    )
  }
  use headers <- result.try(auth.headers(mode, False))
  let req =
    HttpRequest(url:, headers:, body:, timeout_ms: config.http_timeout_ms)
  use raw <- result.try(httpc.transport(req))
  parse(raw)
}

fn request_body(config: OpenAIConfig, request: InferenceRequest) -> String {
  let thinking_level = case request.settings.thinking {
    UseProviderDefault -> config.default_thinking_level
    UseThinkingLevel(level) -> Some(level)
  }
  case config.api {
    ChatCompletions ->
      chat.build_request_body_with_thinking(
        request.messages,
        request.tools,
        config.model,
        thinking_level,
      )
    Responses ->
      responses.build_request_body_with_thinking(
        request.messages,
        request.tools,
        config.model,
        instructions(request.messages),
        thinking_level,
      )
  }
}

fn instructions(messages: List(Message)) -> Option(String) {
  let system_messages =
    list.filter_map(messages, fn(message) {
      case message {
        message.System(content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
  case system_messages {
    [] -> None
    messages -> Some(string.join(messages, "\n\n"))
  }
}
