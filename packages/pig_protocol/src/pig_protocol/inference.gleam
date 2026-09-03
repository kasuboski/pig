import gleam/option.{type Option, None}
import pig_protocol/message.{type Message}
import pig_protocol/stop_reason.{type StopReason}

/// A provider-neutral piece of an assistant response.
///
/// Provider-specific stream fields are normalized into these four forms. Tool
/// calls retain their provider index so parallel calls can be assembled without
/// changing their order.
pub type InferenceDelta {
  /// A fragment of the assistant's visible response.
  TextDelta(text: String)
  /// A fragment of the assistant's reasoning or thinking output.
  ReasoningDelta(text: String)
  /// The first metadata for a tool call at a provider stream index.
  ToolCallStarted(index: Int, id: String, name: String)
  /// A fragment of JSON arguments for a tool call.
  ToolArgumentDelta(index: Int, delta: String)
}

/// Metadata returned by the provider alongside the message.
///
/// `cached_input_tokens` counts input tokens served from a provider-side
/// prompt cache (OpenAI reports them inside usage details). Providers that
/// include cached tokens in `input_tokens` keep that inclusive convention;
/// this field is the cached subset.
pub type InferenceMetadata {
  InferenceMetadata(
    response_id: Option(String),
    response_model: Option(String),
    stop_reason: Option(StopReason),
    input_tokens: Option(Int),
    output_tokens: Option(Int),
    cached_input_tokens: Option(Int),
  )
}

/// Result of a provider call - the message plus metadata from the API response.
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
    cached_input_tokens: None,
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

/// Set cached_input_tokens on metadata.
pub fn with_cached_input_tokens(
  meta: InferenceMetadata,
  tokens: Int,
) -> InferenceMetadata {
  InferenceMetadata(..meta, cached_input_tokens: option.Some(tokens))
}
