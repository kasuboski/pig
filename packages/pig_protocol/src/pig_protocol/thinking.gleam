//// Provider-neutral thinking level configuration.
////
//// Providers translate these levels to their own wire format. A model may
//// reject levels it does not support; Pig intentionally does not maintain a
//// model capability catalog that could become stale.

/// The amount of reasoning a model should perform for an inference.
pub type ThinkingLevel {
  Off
  Minimal
  Low
  Medium
  High
  XHigh
  Max
}

/// Convert a thinking level to its provider-neutral stable string.
pub fn to_string(level: ThinkingLevel) -> String {
  case level {
    Off -> "off"
    Minimal -> "minimal"
    Low -> "low"
    Medium -> "medium"
    High -> "high"
    XHigh -> "xhigh"
    Max -> "max"
  }
}

/// Parse a provider-neutral thinking level string.
pub fn from_string(value: String) -> Result(ThinkingLevel, Nil) {
  case value {
    "off" -> Ok(Off)
    "minimal" -> Ok(Minimal)
    "low" -> Ok(Low)
    "medium" -> Ok(Medium)
    "high" -> Ok(High)
    "xhigh" -> Ok(XHigh)
    "max" -> Ok(Max)
    _ -> Error(Nil)
  }
}

/// Convert a thinking level to the effort names used by OpenAI-shaped APIs.
pub fn to_openai_effort(level: ThinkingLevel) -> String {
  case level {
    Off -> "none"
    Minimal -> "minimal"
    Low -> "low"
    Medium -> "medium"
    High -> "high"
    XHigh -> "xhigh"
    Max -> "max"
  }
}
