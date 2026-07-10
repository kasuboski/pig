//// A normalized stop reason across all LLM providers.
////
//// Each provider maps its native finish/stop reason string to one of
//// these variants. This gives the rest of the codebase a stable,
//// provider-agnostic type to pattern-match on.
////
//// Inspired by pi's `StopReason` type.

import gleam/dynamic/decode
import gleam/json

/// A normalized stop reason across all providers.
pub type StopReason {
  /// The model finished normally (e.g. OpenAI `"stop"`, Anthropic `"end_turn"`)
  Stop
  /// The model hit a token/length limit (e.g. OpenAI `"length"`, Anthropic `"max_tokens"`)
  Length
  /// The model requested tool execution (e.g. OpenAI `"tool_calls"`, Anthropic `"tool_use"`)
  ToolUse
  /// The model stopped due to an error or content filter (e.g. OpenAI `"content_filter"`)
  Error
  /// An unrecognized value from the provider — preserved for forward compatibility
  Unknown(String)
}

// ── Provider Mapping ────────────────────────────────────────────────

/// Map an OpenAI native finish_reason string to a StopReason.
///
/// | OpenAI value     | StopReason |
/// |------------------|------------|
/// | `"stop"`          | `Stop`     |
/// | `"tool_calls"`    | `ToolUse`  |
/// | `"length"`        | `Length`   |
/// | `"content_filter"`| `Error`    |
/// | anything else     | `Unknown`  |
pub fn from_openai(raw: String) -> StopReason {
  case raw {
    "stop" -> Stop
    "tool_calls" -> ToolUse
    "length" -> Length
    "content_filter" -> Error
    other -> Unknown(other)
  }
}

// ── String Conversion ───────────────────────────────────────────────

/// Convert a StopReason to its canonical string representation.
///
/// Used for JSONL serialization, telemetry, and display.
/// `Unknown` values pass through the original provider string.
pub fn to_string(reason: StopReason) -> String {
  case reason {
    Stop -> "stop"
    Length -> "length"
    ToolUse -> "tool_use"
    Error -> "error"
    Unknown(v) -> v
  }
}

/// Parse a canonical string back into a StopReason.
///
/// Inverse of `to_string` for known variants.
/// Unrecognized strings become `Unknown`.
pub fn from_string(s: String) -> StopReason {
  case s {
    "stop" -> Stop
    "length" -> Length
    "tool_use" -> ToolUse
    "error" -> Error
    other -> Unknown(other)
  }
}

// ── JSON ────────────────────────────────────────────────────────────

/// Serialize a StopReason as a JSON string value.
pub fn to_json(reason: StopReason) -> json.Json {
  json.string(to_string(reason))
}

/// Decode a StopReason from a JSON string value.
pub fn decoder() -> decode.Decoder(StopReason) {
  use raw <- decode.map(decode.string)
  from_string(raw)
}
