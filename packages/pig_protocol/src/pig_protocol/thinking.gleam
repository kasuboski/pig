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
