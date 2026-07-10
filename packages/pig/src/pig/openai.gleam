import gleam/result
import pig/provider.{type InferenceResult, type Provider}
import pig_protocol/auth
import pig_protocol/codec/chat
import pig_protocol/error.{type AiError}
import pig_protocol/message.{type Message}
import pig_protocol/tool_definition.{type ToolDefinition}
import pig_protocol/transport.{HttpRequest}
import pig_protocol/transport/httpc

/// Configuration for an OpenAI-compatible Chat Completions provider.
pub type OpenAIConfig {
  OpenAIConfig(
    api_key: String,
    model: String,
    base_url: String,
    http_timeout_ms: Int,
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
  let config = OpenAIConfig(api_key:, model:, base_url:, http_timeout_ms:)
  OpenAIProvider(
    config:,
    call: fn(messages: List(Message), tools: List(ToolDefinition)) -> Result(
      InferenceResult,
      AiError,
    ) {
      do_inference(config, messages, tools)
    },
  )
}

/// Set the HTTP timeout in milliseconds on an OpenAI provider.
pub fn with_http_timeout(
  provider: OpenAIProvider,
  timeout_ms: Int,
) -> OpenAIProvider {
  let config = OpenAIConfig(..provider.config, http_timeout_ms: timeout_ms)
  OpenAIProvider(
    config:,
    call: fn(messages: List(Message), tools: List(ToolDefinition)) -> Result(
      InferenceResult,
      AiError,
    ) {
      do_inference(config, messages, tools)
    },
  )
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

/// Parse an OpenAI Chat Completions JSON response into an InferenceResult.
/// Pure function — no IO.
pub fn parse_response(raw: String) -> Result(InferenceResult, AiError) {
  chat.parse_response(raw)
}

// ─── Internal: inference ───────────────────────────────────────

fn do_inference(
  config: OpenAIConfig,
  messages: List(Message),
  tools: List(ToolDefinition),
) -> Result(InferenceResult, AiError) {
  let mode = auth.StandardApi(config.api_key, config.base_url)
  let url = auth.chat_url(mode)
  use headers <- result.try(auth.headers(mode, False))
  let body = chat.build_request_body(messages, tools, config.model)
  let req = HttpRequest(url:, headers:, body:, timeout_ms: config.http_timeout_ms)
  use raw <- result.try(httpc.transport(req))
  chat.parse_response(raw)
}
