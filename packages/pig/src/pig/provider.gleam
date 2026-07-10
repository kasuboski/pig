import pig_protocol/error.{type AiError}
import pig_protocol/inference
import pig_protocol/message.{type Message}
import pig_protocol/stop_reason.{type StopReason}
import pig_protocol/tool_definition.{type ToolDefinition}

/// Result of a provider call — the message plus metadata from the API response.
pub type InferenceResult = inference.InferenceResult

/// Metadata returned by the provider alongside the message.
pub type InferenceMetadata = inference.InferenceMetadata

/// A provider is a function that takes messages and tool definitions,
/// calls an LLM, and returns either an inference result or an error.
pub type Provider =
  fn(List(Message), List(ToolDefinition)) -> Result(InferenceResult, AiError)

/// Create an InferenceMetadata with all fields set to None.
pub fn default_metadata() -> InferenceMetadata {
  inference.default_metadata()
}

/// Wrap a bare Message into an InferenceResult with default (all-None) metadata.
pub fn from_message(msg: Message) -> InferenceResult {
  inference.from_message(msg)
}

/// Set response_id on metadata.
pub fn with_response_id(meta: InferenceMetadata, id: String) -> InferenceMetadata {
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
