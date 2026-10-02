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

/// Defaults: 64 KiB source and 16 KiB final escaped JSON per direction.
@external(erlang, "pig_otel_content_ffi", "defaults")
pub fn defaults() -> Options

/// Set positive byte budgets (source <= 1 MiB, content <= 256 KiB).
@external(erlang, "pig_otel_content_ffi", "with_limits")
pub fn with_limits(
  options: Options,
  source_bytes: Int,
  content_bytes: Int,
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
