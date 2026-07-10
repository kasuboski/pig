import gleam/option.{type Option, None}
import pig_protocol/message.{type Message}
import pig_protocol/stop_reason.{type StopReason}

/// Metadata returned by the provider alongside the message.
pub type InferenceMetadata {
  InferenceMetadata(
    response_id: Option(String),
    response_model: Option(String),
    stop_reason: Option(StopReason),
    input_tokens: Option(Int),
    output_tokens: Option(Int),
  )
}

/// Result of a provider call — the message plus metadata from the API response.
pub type InferenceResult {
  InferenceResult(message: Message, metadata: InferenceMetadata)
}

/// Create an InferenceMetadata with all fields set to None.
pub fn default_metadata() -> InferenceMetadata {
  InferenceMetadata(
    response_id: None,
    response_model: None,
    stop_reason: None,
    input_tokens: None,
    output_tokens: None,
  )
}

/// Wrap a bare Message into an InferenceResult with default (all-None) metadata.
pub fn from_message(msg: Message) -> InferenceResult {
  InferenceResult(message: msg, metadata: default_metadata())
}

/// Set response_id on metadata.
pub fn with_response_id(
  meta: InferenceMetadata,
  id: String,
) -> InferenceMetadata {
  InferenceMetadata(..meta, response_id: option.Some(id))
}

/// Set response_model on metadata.
pub fn with_response_model(
  meta: InferenceMetadata,
  model: String,
) -> InferenceMetadata {
  InferenceMetadata(..meta, response_model: option.Some(model))
}

/// Set stop_reason on metadata.
pub fn with_stop_reason(
  meta: InferenceMetadata,
  reason: StopReason,
) -> InferenceMetadata {
  InferenceMetadata(..meta, stop_reason: option.Some(reason))
}

/// Set input_tokens on metadata.
pub fn with_input_tokens(
  meta: InferenceMetadata,
  tokens: Int,
) -> InferenceMetadata {
  InferenceMetadata(..meta, input_tokens: option.Some(tokens))
}

/// Set output_tokens on metadata.
pub fn with_output_tokens(
  meta: InferenceMetadata,
  tokens: Int,
) -> InferenceMetadata {
  InferenceMetadata(..meta, output_tokens: option.Some(tokens))
}
