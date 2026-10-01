//// Bounded, opt-in conversation projection for the two proxy OpenAI APIs.
//// Provider media/reasoning parts, unknown fields and tool schemas are excluded.
//// Key/literal redaction cannot guarantee that arbitrary prose is secret-free.
//// Host SDK string truncation can invalidate these otherwise complete JSON values.

import gleam/list
import otel/attribute
import pig_otel

/// Validated, per-operation budgets and declarative redaction rules.
/// This foreign type has no public constructor; use the validated builders.
pub type Options

/// Finite configuration failures; no supplied rule is reflected in an error.
pub type OptionsError {
  InvalidLimits
  TooManyRules
  InvalidRule
}

/// A schema-projected result, never a raw provider body.
/// This foreign type has no public constructor.
pub type Capture

/// Attribute direction. Input-only attributes cannot become output attributes.
pub type Direction {
  Input
  Output
}

/// Pure incremental SSE state; failed states retain no provider bytes.
pub type Stream

/// Defaults: 64 KiB source and 16 KiB final escaped JSON per direction.
@external(erlang, "pig_proxy_content_ffi", "defaults")
pub fn defaults() -> Options

/// Set positive byte budgets (source <= 1 MiB, content <= 256 KiB).
@external(erlang, "pig_proxy_content_ffi", "with_limits")
pub fn with_limits(
  options: Options,
  source_bytes: Int,
  content_bytes: Int,
) -> Result(Options, OptionsError)

/// Extend default case-insensitive key-fragment rules (32 rules, 128 bytes each).
@external(erlang, "pig_proxy_content_ffi", "with_redacted_keys")
pub fn with_redacted_keys(
  options: Options,
  keys: List(String),
) -> Result(Options, OptionsError)

/// Add literal redactions (32 rules, 256 bytes each). Matching identities omit
/// the capture rather than altering tool call/result linkage.
@external(erlang, "pig_proxy_content_ffi", "with_redacted_text")
pub fn with_redacted_text(
  options: Options,
  literals: List(String),
) -> Result(Options, OptionsError)

/// Project an effective request, including separate Responses instructions.
@external(erlang, "pig_proxy_content_ffi", "input")
pub fn input(options: Options, api: pig_otel.Api, body: BitArray) -> Capture

/// Project a completed buffered provider response; failures never expose bodies.
@external(erlang, "pig_proxy_content_ffi", "buffered")
pub fn buffered(options: Options, api: pig_otel.Api, body: BitArray) -> Capture

/// Start bounded SSE capture. Source budget includes framing and ignored events.
@external(erlang, "pig_proxy_content_ffi", "new_stream")
pub fn new_stream(options: Options, api: pig_otel.Api) -> Stream

/// Observe a chunk without affecting transport. Overflow permanently drops state.
@external(erlang, "pig_proxy_content_ffi", "push")
pub fn push(stream: Stream, chunk: BitArray) -> Stream

/// Finalize only at the owner's ordered source terminal. A finish reason alone
/// never ends capture; incomplete, malformed and unfinished outputs are omitted.
@external(erlang, "pig_proxy_content_ffi", "finish")
pub fn finish(stream: Stream, complete: Bool) -> Capture

/// Bytes of provider payload retained by the current state, excluding options.
@external(erlang, "pig_proxy_content_ffi", "retained_bytes")
pub fn retained_bytes(stream: Stream) -> Int

@external(erlang, "pig_proxy_content_ffi", "pairs")
fn pairs(capture: Capture, direction: Direction) -> List(#(String, String))

/// Use the existing binding's JSON-string attributes, with finite private status.
pub fn attributes(
  capture: Capture,
  direction: Direction,
) -> List(attribute.Attribute) {
  list.map(pairs(capture, direction), fn(pair) {
    // Keys are generated constants at the projection boundary, never provider data.
    let assert Ok(key) = attribute.key(pair.0)
    attribute.string(key, pair.1)
  })
}
