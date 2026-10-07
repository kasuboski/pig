//// Validated limits and redaction rules shared by Pig and proxy capture.

/// Validated, per-operation budgets and declarative redaction rules.
/// This foreign type has no public constructor; use the validated builders.
pub type Options

/// Finite configuration failures; no supplied rule is reflected in an error.
pub type OptionsError {
  InvalidLimits
  TooManyRules
  InvalidRule
}

/// Defaults: input source 4 MiB/content 2 MiB; output source 4 MiB/content 64 KiB.
@external(erlang, "pig_otel_content_ffi", "defaults")
pub fn defaults() -> Options

/// Set positive byte budgets for both directions (source <= 4 MiB, content <= 2 MiB).
@external(erlang, "pig_otel_content_ffi", "with_limits")
pub fn with_limits(
  options: Options,
  source_bytes: Int,
  content_bytes: Int,
) -> Result(Options, OptionsError)

/// Direction-specific validated budgets.
pub type Limits {
  InputLimits(source_bytes: Int, content_bytes: Int)
  OutputLimits(source_bytes: Int, content_bytes: Int)
}

/// Set one direction's budgets (source <= 4 MiB, content <= 2 MiB).
@external(erlang, "pig_otel_content_ffi", "with_direction_limits")
pub fn with_direction_limits(
  options: Options,
  limits: Limits,
) -> Result(Options, OptionsError)

/// Extend default case-insensitive key-fragment rules (32 rules, 128 bytes each).
@external(erlang, "pig_otel_content_ffi", "with_redacted_keys")
pub fn with_redacted_keys(
  options: Options,
  keys: List(String),
) -> Result(Options, OptionsError)

/// Add literal redactions (32 rules, 256 bytes each). Matching identities omit
/// the capture rather than altering tool call/result linkage.
@external(erlang, "pig_otel_content_ffi", "with_redacted_text")
pub fn with_redacted_text(
  options: Options,
  literals: List(String),
) -> Result(Options, OptionsError)
