//// Shared bounded conversation projection for Pig and OpenAI-compatible proxies.
//// Provider media/reasoning parts, unknown fields and tool schemas are excluded.
//// Key/literal redaction cannot guarantee that arbitrary prose is secret-free.
//// Host SDK string truncation can invalidate these otherwise complete JSON values.

import gleam/list
import gleam/option.{type Option}
import otel/attribute
import pig_otel
import pig_otel/content/options.{type Options}
import pig_protocol/message.{type Message}
import pig_protocol/stop_reason.{type StopReason}
import pig_protocol/tool_definition.{type ToolDefinition}

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

/// Capture a normalized request without provider-specific wire fields. Tool
/// descriptions and schemas are intentionally excluded.
@external(erlang, "pig_otel_content_ffi", "normalized_input")
pub fn normalized_input(
  options: Options,
  system_prompt: Option(String),
  messages: List(Message),
  tools: List(ToolDefinition),
) -> Capture

/// Capture only completed assistant output with a known normalized stop reason.
@external(erlang, "pig_otel_content_ffi", "normalized_output")
pub fn normalized_output(
  options: Options,
  message: Message,
  stop_reason: Option(StopReason),
) -> Capture

/// Return a finite omission marker for incomplete or unavailable output.
@external(erlang, "pig_otel_content_ffi", "incomplete")
pub fn incomplete() -> Capture

/// Project an effective request, including separate Responses instructions.
@external(erlang, "pig_otel_content_ffi", "input")
pub fn input(options: Options, api: pig_otel.Api, body: BitArray) -> Capture

/// Project a completed buffered provider response; failures never expose bodies.
@external(erlang, "pig_otel_content_ffi", "buffered")
pub fn buffered(options: Options, api: pig_otel.Api, body: BitArray) -> Capture

/// Start bounded SSE capture. Source budget includes framing and ignored events.
@external(erlang, "pig_otel_content_ffi", "new_stream")
pub fn new_stream(options: Options, api: pig_otel.Api) -> Stream

/// Observe a chunk without affecting transport. Overflow permanently drops state.
@external(erlang, "pig_otel_content_ffi", "push")
pub fn push(stream: Stream, chunk: BitArray) -> Stream

/// Finalize only at the owner's ordered source terminal. A finish reason alone
/// never ends capture; incomplete and malformed outputs are omitted. Unfinished
/// stream items are excluded from a completed capture and mark it filtered.
@external(erlang, "pig_otel_content_ffi", "finish")
pub fn finish(stream: Stream, complete: Bool) -> Capture

/// Bytes of provider payload retained by the current state, excluding options.
@external(erlang, "pig_otel_content_ffi", "retained_bytes")
pub fn retained_bytes(stream: Stream) -> Int

@external(erlang, "pig_otel_content_ffi", "pairs")
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
