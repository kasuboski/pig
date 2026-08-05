//// The provider abstraction and metadata setters used by `pig` and its
//// generated consumers.
////
//// A `Provider` is a function from an inference request to an
//// `InferenceResult`. Concrete providers (Chat Completions, Codex
//// Responses, etc.) live behind constructors that hide their transport
//// details. `pig/openai` provides the standard OpenAI-shaped one.

import pig_protocol/error.{type AiError}
import pig_protocol/inference
import pig_protocol/message.{type Message}
import pig_protocol/stop_reason.{type StopReason}
import pig_protocol/thinking
import pig_protocol/tool_definition.{type ToolDefinition}

/// The thinking configuration for one inference request.
pub type ThinkingSetting {
  /// Let the provider choose whether and how to think.
  UseProviderDefault
  /// Request a specific thinking level for this inference.
  UseThinkingLevel(thinking.ThinkingLevel)
}

/// Inference settings passed to a provider.
pub type InferenceSettings {
  InferenceSettings(thinking: ThinkingSetting)
}

/// The messages, tools, and settings for one provider call.
pub type InferenceRequest {
  InferenceRequest(
    messages: List(Message),
    tools: List(ToolDefinition),
    settings: InferenceSettings,
  )
}

/// Return settings that defer thinking configuration to the provider.
pub fn default_settings() -> InferenceSettings {
  InferenceSettings(thinking: UseProviderDefault)
}

/// Return settings requesting the given thinking level.
pub fn with_thinking_level(level: thinking.ThinkingLevel) -> InferenceSettings {
  InferenceSettings(thinking: UseThinkingLevel(level))
}

/// Encode inference settings using the stable provider-neutral representation
/// persisted in telemetry and JSONL session events.
pub fn settings_to_string(settings: InferenceSettings) -> String {
  case settings {
    InferenceSettings(thinking: UseProviderDefault) -> "provider_default"
    InferenceSettings(thinking: UseThinkingLevel(level)) ->
      thinking.to_string(level)
  }
}

/// Decode the stable provider-neutral representation of inference settings.
pub fn settings_from_string(value: String) -> Result(InferenceSettings, Nil) {
  case value {
    "provider_default" -> Ok(default_settings())
    _ ->
      case thinking.from_string(value) {
        Ok(level) -> Ok(with_thinking_level(level))
        Error(Nil) -> Error(Nil)
      }
  }
}

/// Result of a provider call — the message plus metadata from the API response.
pub type InferenceResult =
  inference.InferenceResult

/// Metadata returned by the provider alongside the message.
pub type InferenceMetadata =
  inference.InferenceMetadata

/// A provider takes an inference request, calls an LLM, and returns either
/// an inference result or an error.
pub type Provider =
  fn(InferenceRequest) -> Result(InferenceResult, AiError)

/// Create an InferenceMetadata with all fields set to None.
pub fn default_metadata() -> InferenceMetadata {
  inference.default_metadata()
}

/// Wrap a bare Message into an InferenceResult with default (all-None) metadata.
pub fn from_message(msg: Message) -> InferenceResult {
  inference.from_message(msg)
}

/// Set response_id on metadata.
pub fn with_response_id(
  meta: InferenceMetadata,
  id: String,
) -> InferenceMetadata {
  inference.with_response_id(meta, id)
}

/// Set response_model on metadata.
pub fn with_response_model(
  meta: InferenceMetadata,
  model: String,
) -> InferenceMetadata {
  inference.with_response_model(meta, model)
}

/// Set stop_reason on metadata.
pub fn with_stop_reason(
  meta: InferenceMetadata,
  reason: StopReason,
) -> InferenceMetadata {
  inference.with_stop_reason(meta, reason)
}

/// Set input_tokens on metadata.
pub fn with_input_tokens(
  meta: InferenceMetadata,
  tokens: Int,
) -> InferenceMetadata {
  inference.with_input_tokens(meta, tokens)
}

/// Set output_tokens on metadata.
pub fn with_output_tokens(
  meta: InferenceMetadata,
  tokens: Int,
) -> InferenceMetadata {
  inference.with_output_tokens(meta, tokens)
}
