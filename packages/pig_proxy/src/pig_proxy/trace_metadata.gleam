//// Bounded, metadata-only response decoding. No generated content is retained.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import pig_otel
import pig_protocol/inference
import pig_protocol/sse
import pig_protocol/stop_reason

/// Incremental framing state, capped at 4 MiB per event. Oversized events
/// are discarded through their delimiter, not parsed as truncated JSON.
pub type Framer

/// Observed API metadata and an explicit model-level failure, if any.
pub type Observed {
  Observed(metadata: inference.InferenceMetadata, failed: Bool)
}

/// Start an empty bounded decoder.
@external(erlang, "pig_proxy_trace_metadata_ffi", "new")
pub fn new_framer() -> Framer

@external(erlang, "pig_proxy_trace_metadata_ffi", "push")
fn frames(framer: Framer, chunk: BitArray) -> #(Framer, List(String))

@external(erlang, "pig_proxy_trace_metadata_ffi", "finish")
fn trailing(framer: Framer) -> List(String)

/// Bytes retained by the current frame, excluding discarded oversized data.
@external(erlang, "pig_proxy_trace_metadata_ffi", "retained_bytes")
pub fn retained_bytes(framer: Framer) -> Int

/// No absent field is replaced with a fabricated zero.
pub fn empty() -> Observed {
  Observed(inference.default_metadata(), False)
}

/// Parse a buffered response using its actual API shape.
pub fn buffered(api: pig_otel.Api, body: String) -> Observed {
  result.unwrap(json.parse(body, decoder(api)), empty())
}

/// Incrementally observe complete SSE frames, independently of downstream sends.
pub fn push(
  api: pig_otel.Api,
  framer: Framer,
  observed: Observed,
  chunk: BitArray,
) -> #(Framer, Observed) {
  let #(next, complete) = frames(framer, chunk)
  #(
    next,
    list.fold(complete, observed, fn(acc, frame) {
      merge(acc, event(api, frame))
    }),
  )
}

/// Include a bounded trailing frame before upstream terminal finalization.
pub fn finish(
  api: pig_otel.Api,
  framer: Framer,
  observed: Observed,
) -> Observed {
  list.fold(trailing(framer), observed, fn(acc, frame) {
    merge(acc, event(api, frame))
  })
}

fn event(api: pig_otel.Api, frame: String) -> Observed {
  let data = sse.frame_data(frame)
  let decoder = case api {
    pig_otel.Responses -> responses_event_decoder()
    _ -> decoder(api)
  }
  result.unwrap(json.parse(data, decoder), empty())
}

@external(erlang, "binary", "copy")
fn copy_string(value: String) -> String

fn bounded(value: Option(String)) -> Option(String) {
  case value {
    Some(text) ->
      case bit_array.byte_size(bit_array.from_string(text)) <= 256 {
        True -> Some(copy_string(text))
        False -> None
      }
    None -> None
  }
}

fn token_decoder() -> decode.Decoder(Option(Int)) {
  decode.map(decode.optional(decode.int), fn(value) {
    case value {
      Some(n) if n >= 0 -> Some(n)
      _ -> None
    }
  })
}

fn usage_decoder(
  api: pig_otel.Api,
) -> decode.Decoder(inference.InferenceMetadata) {
  let #(input, output, details) = case api {
    pig_otel.Responses -> #(
      "input_tokens",
      "output_tokens",
      "input_tokens_details",
    )
    _ -> #("prompt_tokens", "completion_tokens", "prompt_tokens_details")
  }
  use input_tokens <- decode.optional_field(input, None, token_decoder())
  use output_tokens <- decode.optional_field(output, None, token_decoder())
  use cached_input_tokens <- decode.optional_field(
    details,
    None,
    decode.optional(cached_decoder()),
  )
  decode.success(
    inference.InferenceMetadata(
      ..inference.default_metadata(),
      input_tokens:,
      output_tokens:,
      cached_input_tokens: option.flatten(cached_input_tokens),
    ),
  )
}

fn cached_decoder() -> decode.Decoder(Option(Int)) {
  use tokens <- decode.optional_field("cached_tokens", None, token_decoder())
  decode.success(tokens)
}

fn choice_decoder() -> decode.Decoder(Option(String)) {
  use reason <- decode.optional_field(
    "finish_reason",
    None,
    decode.optional(decode.string),
  )
  decode.success(reason)
}

fn decoder(api: pig_otel.Api) -> decode.Decoder(Observed) {
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  use model <- decode.optional_field(
    "model",
    None,
    decode.optional(decode.string),
  )
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(usage_decoder(api)),
  )
  use choices <- decode.optional_field(
    "choices",
    [],
    decode.list(choice_decoder()),
  )
  use status <- decode.optional_field(
    "status",
    None,
    decode.optional(decode.string),
  )
  use incomplete_reason <- decode.optional_field(
    "incomplete_details",
    None,
    decode.optional(decode.at(["reason"], decode.string)),
  )
  let finish = case api {
    pig_otel.Responses ->
      case incomplete_reason {
        Some("content_filter") -> Some(stop_reason.Error)
        Some("max_output_tokens") -> Some(stop_reason.Length)
        _ -> option.map(status, stop_reason.from_responses_status)
      }
    _ ->
      option.map(
        result.unwrap(list.first(choices), None),
        stop_reason.from_openai,
      )
  }
  let finish = case finish {
    Some(stop_reason.Unknown(_)) -> None
    value -> value
  }
  let metadata = option.unwrap(usage, inference.default_metadata())
  decode.success(Observed(
    inference.InferenceMetadata(
      ..metadata,
      response_id: bounded(id),
      response_model: bounded(model),
      stop_reason: finish,
    ),
    finish == Some(stop_reason.Error),
  ))
}

fn responses_event_decoder() -> decode.Decoder(Observed) {
  use type_ <- decode.optional_field("type", "", decode.string)
  use response <- decode.optional_field(
    "response",
    empty(),
    decoder(pig_otel.Responses),
  )
  decode.success(
    Observed(
      ..response,
      failed: response.failed || type_ == "error" || type_ == "response.failed",
    ),
  )
}

fn prefer(new: Option(a), old: Option(a)) -> Option(a) {
  case new {
    Some(_) -> new
    None -> old
  }
}

/// Merge only present fields; late usage cannot erase earlier identity/finish.
pub fn merge(old: Observed, new: Observed) -> Observed {
  let a = old.metadata
  let b = new.metadata
  Observed(
    inference.InferenceMetadata(
      response_id: prefer(b.response_id, a.response_id),
      response_model: prefer(b.response_model, a.response_model),
      stop_reason: prefer(b.stop_reason, a.stop_reason),
      input_tokens: prefer(b.input_tokens, a.input_tokens),
      output_tokens: prefer(b.output_tokens, a.output_tokens),
      cached_input_tokens: prefer(b.cached_input_tokens, a.cached_input_tokens),
    ),
    old.failed || new.failed,
  )
}
