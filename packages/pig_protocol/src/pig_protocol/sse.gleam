//// Parsers for OpenAI Server-Sent Events (SSE) streams.
////
//// Handles two streams:
////   - Chat Completions: `parse_chat_line` decodes per-token deltas.
////   - Responses API (Codex): `parse_responses_event` decodes typed events
////     keyed off the event's `type` field.
////
//// Pure — no IO. The transport layer (`pig_protocol/transport/httpc`)
//// is responsible for delivering the raw bytes.

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

/// Split a buffer into complete SSE frames and any trailing partial frame.
///
/// SSE frames are separated by two consecutive newlines (`\n\n`). The
/// returned remainder should be prepended to the next chunk of bytes.
pub fn split_frames(buffer: String) -> #(List(String), String) {
  case string.split_once(buffer, "\n\n") {
    Ok(#(frame, rest)) -> {
      let #(frames, remaining) = split_frames(rest)
      #([frame, ..frames], remaining)
    }
    Error(Nil) -> #([], buffer)
  }
}

/// Extract the concatenated `data:` payload from an SSE frame.
///
/// Ignores `id:`, `event:`, and comment lines. Multiple `data:` lines are
/// joined with a newline before being trimmed.
pub fn frame_data(frame: String) -> String {
  string.split(frame, "\n")
  |> list.filter(fn(line) { string.starts_with(line, "data:") })
  |> list.map(fn(line) { string.drop_start(line, 5) |> string.trim })
  |> string.join("\n")
  |> string.trim
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

    "error" ->
      decode.map(error_message_decoder(), ResponseError)

    _ ->
      decode.success(OtherResponseEvent)
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
  decode.success(
    inference.InferenceMetadata(
      response_id: Some(id),
      response_model: Some(model),
      stop_reason: Some(stop),
      input_tokens: option.map(usage, fn(u) { u.input_tokens }),
      output_tokens: option.map(usage, fn(u) { u.output_tokens }),
    ),
  )
}

fn error_message_decoder() -> decode.Decoder(String) {
  use direct <- decode.optional_field("message", "", decode.string)
  case direct {
    "" -> {
      use msg <- decode.subfield(["error", "message"], decode.string)
      decode.success(msg)
    }
    _ ->
      decode.success(direct)
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
