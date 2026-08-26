//// Parsers for OpenAI Server-Sent Events (SSE) streams.
////
//// Handles two streams:
////   - Chat Completions: `parse_chat_line` decodes per-token deltas.
////   - Responses API (Codex): `parse_responses_event` decodes typed events
////     keyed off the event's `type` field.
////
//// The framing decoder is pure and operates on byte chunks. It does not
//// convert a network chunk to a string until a complete event is available.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import pig_protocol/inference.{type InferenceMetadata}
import pig_protocol/stop_reason

/// A decoded delta from a Chat Completions SSE stream.
pub type StreamDelta {
  ContentChunk(String)
  UsageChunk(input: Int, output: Int)
  StreamDone
}

/// A decoded event from an OpenAI Responses API (Codex) SSE stream.
pub type ResponsesEvent {
  ResponseCreated(id: String)
  OutputTextDelta(delta: String)
  FunctionCallArgumentsDelta(delta: String)
  FunctionCallArgumentsDone(arguments: String)
  ResponseCompleted(metadata: InferenceMetadata)
  ResponseIncomplete(metadata: InferenceMetadata)
  ResponseFailed(message: String)
  ResponseError(message: String)
  OtherResponseEvent
}

/// The pure state carried between raw network chunks.
///
/// The buffer is kept as bytes so a UTF-8 code point split across chunks is
/// not decoded prematurely.
pub opaque type Decoder {
  Decoder(buffer: BitArray)
}

/// The framing decoder could not decode a complete event as UTF-8.
pub type DecoderError {
  InvalidUtf8
}

/// Create an empty SSE frame decoder.
pub fn new() -> Decoder {
  Decoder(buffer: <<>>)
}

/// Add one byte chunk and return complete SSE frames plus the new decoder.
///
/// Frames do not include their blank-line delimiter. The returned strings are
/// only decoded after the delimiter is found, so chunks may split delimiters
/// and multibyte UTF-8 code points safely.
pub fn push(
  decoder: Decoder,
  chunk: BitArray,
) -> Result(#(Decoder, List(String)), DecoderError) {
  let buffer = bit_array.append(decoder.buffer, chunk)
  case take_frames(buffer, []) {
    Ok(#(frames, remainder)) -> Ok(#(Decoder(buffer: remainder), frames))
    Error(error) -> Error(error)
  }
}

/// Finish a stream and emit one event if bytes remain without a final blank
/// line. A trailing partial line is valid at end of an SSE response.
pub fn finish(decoder: Decoder) -> Result(List(String), DecoderError) {
  case bit_array.to_string(decoder.buffer) {
    Ok(frame) ->
      Ok(case frame {
        "" -> []
        _ -> [frame]
      })
    Error(_) -> Error(InvalidUtf8)
  }
}

/// Split a buffer into complete SSE frames and any trailing partial frame.
///
/// This string-based helper is retained for callers that already have a
/// decoded response. New streaming callers should use `new`, `push`, and
/// `finish` so decoding is deferred until a complete frame is available.
pub fn split_frames(buffer: String) -> #(List(String), String) {
  let bits = bit_array.from_string(buffer)
  let assert Ok(#(frames, remainder)) = take_frames(bits, [])
  let assert Ok(remainder_string) = bit_array.to_string(remainder)
  #(frames, remainder_string)
}

/// Extract the concatenated `data:` payload from an SSE frame.
///
/// Ignores comments and unknown fields. Multiple `data:` lines are joined
/// with a newline, as required by the SSE event stream format. The single
/// optional space after `data:` is removed, but all other payload whitespace
/// is preserved.
pub fn frame_data(frame: String) -> String {
  frame
  |> string.replace("\r\n", "\n")
  |> string.replace("\r", "\n")
  |> string.split("\n")
  |> list.fold([], fn(lines, line) { collect_data_line(line, lines) })
  |> list.reverse
  |> string.join("\n")
}

/// Parse a single `data:` payload from a Chat Completions stream.
///
/// Returns `StreamDone` for `[DONE]`, `UsageChunk` for a final usage frame,
/// and `ContentChunk` for a token delta.
pub fn parse_chat_line(data: String) -> Result(StreamDelta, Nil) {
  case string.trim(data) {
    "[DONE]" -> Ok(StreamDone)
    trimmed ->
      case json.parse(from: trimmed, using: chat_delta_decoder()) {
        Ok(inner) -> inner
        Error(_) -> Error(Nil)
      }
  }
}

/// Parse a single `data:` payload from a Responses API stream.
pub fn parse_responses_event(data: String) -> ResponsesEvent {
  case json.parse(from: data, using: responses_event_decoder()) {
    Ok(event) -> event
    Error(_) -> OtherResponseEvent
  }
}

fn take_frames(
  buffer: BitArray,
  frames: List(String),
) -> Result(#(List(String), BitArray), DecoderError) {
  case find_delimiter(buffer, 0) {
    Error(Nil) -> Ok(#(list.reverse(frames), buffer))
    Ok(#(frame_size, delimiter_size)) -> {
      let assert Ok(frame_bits) = bit_array.slice(buffer, 0, frame_size)
      let remaining_size =
        bit_array.byte_size(buffer) - frame_size - delimiter_size
      let assert Ok(remaining) =
        bit_array.slice(buffer, frame_size + delimiter_size, remaining_size)
      case bit_array.to_string(frame_bits) {
        Ok(frame) -> take_frames(remaining, [frame, ..frames])
        Error(_) -> Error(InvalidUtf8)
      }
    }
  }
}

fn find_delimiter(buffer: BitArray, consumed: Int) -> Result(#(Int, Int), Nil) {
  case buffer {
    <<10, rest:bits>> -> find_second_line_ending(rest, consumed, 1)
    <<13, 10, rest:bits>> -> find_second_line_ending(rest, consumed, 2)
    <<13, rest:bits>> -> {
      case rest {
        <<>> -> Error(Nil)
        _ -> find_second_line_ending(rest, consumed, 1)
      }
    }
    <<_byte, rest:bits>> -> find_delimiter(rest, consumed + 1)
    <<>> -> Error(Nil)
    _ -> Error(Nil)
  }
}

fn find_second_line_ending(
  buffer: BitArray,
  consumed: Int,
  first_size: Int,
) -> Result(#(Int, Int), Nil) {
  case buffer {
    <<10, _rest:bits>> -> Ok(#(consumed, first_size + 1))
    <<13, 10, _rest:bits>> -> Ok(#(consumed, first_size + 2))
    <<13, rest:bits>> -> {
      case rest {
        <<>> -> Error(Nil)
        _ -> Ok(#(consumed, first_size + 1))
      }
    }
    <<_byte, rest:bits>> -> find_delimiter(rest, consumed + first_size + 1)
    <<>> -> Error(Nil)
    _ -> Error(Nil)
  }
}

fn collect_data_line(line: String, lines: List(String)) -> List(String) {
  case string.starts_with(line, "data:") {
    True -> [data_value(line), ..lines]
    False -> lines
  }
}

fn data_value(line: String) -> String {
  let value = string.drop_start(line, 5)
  case string.starts_with(value, " ") {
    True -> string.drop_start(value, 1)
    False -> value
  }
}

// ─── Chat Completions stream decoding ──────────────────────────

type ChatUsage {
  ChatUsage(prompt_tokens: Int, completion_tokens: Int)
}

fn chat_delta_decoder() -> decode.Decoder(Result(StreamDelta, Nil)) {
  use choices <- decode.field(
    "choices",
    decode.list(chat_choice_content_decoder()),
  )
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(chat_usage_decoder()),
  )
  decode.success(case choices {
    [] ->
      case usage {
        Some(u) -> Ok(UsageChunk(u.prompt_tokens, u.completion_tokens))
        None -> Error(Nil)
      }
    [first, ..] ->
      case first {
        Some(text) -> Ok(ContentChunk(text))
        None -> Error(Nil)
      }
  })
}

fn chat_choice_content_decoder() -> decode.Decoder(Option(String)) {
  use content <- decode.subfield(
    ["delta", "content"],
    decode.optional(decode.string),
  )
  decode.success(content)
}

fn chat_usage_decoder() -> decode.Decoder(ChatUsage) {
  use prompt_tokens <- decode.field("prompt_tokens", decode.int)
  use completion_tokens <- decode.field("completion_tokens", decode.int)
  decode.success(ChatUsage(prompt_tokens:, completion_tokens:))
}

// ─── Responses API stream decoding ─────────────────────────────

fn responses_event_decoder() -> decode.Decoder(ResponsesEvent) {
  use event_type <- decode.field("type", decode.string)
  case event_type {
    "response.created" -> {
      use id <- decode.subfield(["response", "id"], decode.string)
      decode.success(ResponseCreated(id))
    }

    "response.output_text.delta" -> {
      use delta <- decode.field("delta", decode.string)
      decode.success(OutputTextDelta(delta))
    }

    "response.function_call_arguments.delta" -> {
      use delta <- decode.field("delta", decode.string)
      decode.success(FunctionCallArgumentsDelta(delta))
    }

    "response.function_call_arguments.done" -> {
      use arguments <- decode.field("arguments", decode.string)
      decode.success(FunctionCallArgumentsDone(arguments))
    }

    "response.completed" ->
      decode.map(completed_response_decoder(), ResponseCompleted)

    "response.incomplete" ->
      decode.map(completed_response_decoder(), ResponseIncomplete)

    "response.failed" -> {
      use message <- decode.subfield(
        ["response", "error", "message"],
        decode.string,
      )
      decode.success(ResponseFailed(message))
    }

    "error" -> decode.map(error_message_decoder(), ResponseError)

    _ -> decode.success(OtherResponseEvent)
  }
}

fn completed_response_decoder() -> decode.Decoder(InferenceMetadata) {
  use id <- decode.subfield(["response", "id"], decode.string)
  use model <- decode.subfield(["response", "model"], decode.string)
  use status <- decode.subfield(["response", "status"], decode.string)
  // `incomplete_details` is only meaningful when the response was cut short,
  // but some providers include it on completed responses too. We read it
  // optionally and let it override the status-based stop reason when present.
  use incomplete_reason <- decode.optional_field(
    "incomplete_details",
    None,
    decode.optional(decode.at(["reason"], decode.string)),
  )
  use usage <- decode.subfield(
    ["response", "usage"],
    decode.optional(usage_decoder()),
  )
  let stop = case incomplete_reason {
    Some("content_filter") -> stop_reason.Error
    Some("max_output_tokens") -> stop_reason.Length
    _ -> stop_reason.from_responses_status(status)
  }
  decode.success(inference.InferenceMetadata(
    response_id: Some(id),
    response_model: Some(model),
    stop_reason: Some(stop),
    input_tokens: option.map(usage, fn(u) { u.input_tokens }),
    output_tokens: option.map(usage, fn(u) { u.output_tokens }),
  ))
}

fn error_message_decoder() -> decode.Decoder(String) {
  use direct <- decode.optional_field("message", "", decode.string)
  case direct {
    "" -> {
      use msg <- decode.subfield(["error", "message"], decode.string)
      decode.success(msg)
    }
    _ -> decode.success(direct)
  }
}

type Usage {
  Usage(input_tokens: Int, output_tokens: Int, total_tokens: Int)
}

fn usage_decoder() -> decode.Decoder(Usage) {
  use input_tokens <- decode.field("input_tokens", decode.int)
  use output_tokens <- decode.field("output_tokens", decode.int)
  use total_tokens <- decode.field("total_tokens", decode.int)
  decode.success(Usage(input_tokens:, output_tokens:, total_tokens:))
}
