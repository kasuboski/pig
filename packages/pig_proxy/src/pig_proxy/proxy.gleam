//// Core proxy logic: header scrubbing, credential injection, and request
//// forwarding (both streaming and non-streaming).
////
//// The proxy acts as a security perimeter — it strips client-supplied
//// credentials, injects the correct upstream key from its config, and
//// pipes the response back. For streaming requests (`"stream": true`),
//// chunks are relayed in real time via a dedicated process so the proxy
//// never buffers the entire payload.

import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import logging
import mist
import pig_protocol/auth
import pig_protocol/sse
import pig_proxy/config.{type UpstreamTarget}
import pig_proxy/hackney
import pig_proxy/telemetry
import pig_transport as transport

/// State held by the streaming chunked loop: accumulated token usage, the
/// byte-safe SSE decoder, and the upstream opaque handle so it can be
/// cancelled if the client disconnects.
type StreamState {
  StreamState(
    usage: Usage,
    decoder: sse.Decoder,
    handle: transport.StreamHandle,
  )
}

// ── Header scrubbing & injection ────────────────────────────────

/// Headers that must be stripped from client requests.
/// The proxy is the security perimeter — no client credentials pass through.
/// Content-type and accept are also stripped because the proxy injects
/// its own values to avoid duplicate headers.
fn is_strip_header(key: String) -> Bool {
  let key_lower = string.lowercase(key)
  list.contains(
    [
      "authorization",
      "api-key",
      "proxy-authorization",
      "host",
      "connection",
      "content-length",
      "transfer-encoding",
      "content-type",
      "accept",
      "chatgpt-account-id",
      "openai-beta",
      "originator",
    ],
    key_lower,
  )
}

/// Remove client-supplied auth, hop-by-hop, and proxy-managed headers.
pub fn scrub_headers(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  list.filter(headers, fn(h) { !is_strip_header(h.0) })
}

/// Inject the upstream API key as a Bearer token.
pub fn inject_api_key(
  headers: List(#(String, String)),
  api_key: String,
) -> List(#(String, String)) {
  [#("authorization", "Bearer " <> api_key), ..headers]
}

/// The concrete authentication to apply to an upstream request: a mode
/// plus a resolved token. The credential vault resolves a target's
/// `TargetAuth` into one of these at request time (`execution.resolve_auth`).
pub type ResolvedAuth {
  ApiKey(key: String)
  Codex(token: String)
}

/// Build the full header list for an upstream request: scrubbed client
/// headers plus injected auth and JSON content headers.
///
/// A `Codex` credential gets the Codex Responses API header set —
/// `chatgpt-account-id` derived from the JWT, plus the required
/// `OpenAI-Beta`/`originator` headers — instead of a plain Bearer key. If
/// the token can't be decoded (e.g. malformed JWT), this falls back to
/// plain Bearer injection and logs a warning rather than failing the
/// request outright.
pub fn build_upstream_headers(
  client_headers: List(#(String, String)),
  base_url: String,
  credential: ResolvedAuth,
  streaming: Bool,
) -> List(#(String, String)) {
  let scrubbed = scrub_headers(client_headers)
  case credential {
    Codex(token) ->
      case auth.headers(auth.CodexOAuth(token, base_url), streaming) {
        Ok(codex_headers) -> list.append(scrubbed, codex_headers)
        Error(_) -> {
          logging.log(
            logging.Warning,
            "proxy: failed to derive chatgpt-account-id — falling back to"
              <> " plain bearer injection",
          )
          bearer_headers(scrubbed, token, streaming)
        }
      }
    ApiKey(key) -> bearer_headers(scrubbed, key, streaming)
  }
}

fn bearer_headers(
  scrubbed_headers: List(#(String, String)),
  key: String,
  streaming: Bool,
) -> List(#(String, String)) {
  let accept = case streaming {
    True -> "text/event-stream"
    False -> "application/json"
  }
  scrubbed_headers
  |> inject_api_key(key)
  |> list.append([
    #("content-type", "application/json"),
    #("accept", accept),
  ])
}

// ── URL resolution ──────────────────────────────────────────────

/// Trim trailing slashes from a URL.
fn trim_trailing_slash(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> trim_trailing_slash(string.drop_end(url, 1))
    False -> url
  }
}

/// Resolve the upstream URL for a given client path and target.
///
/// The client sends to `/v1/chat/completions`; the target base_url already
/// includes `/v1`. We strip a leading `/v1` from the client path and append
/// the remainder to the target base_url. If the client path does not start
/// with `/v1`, it is appended unchanged.
pub fn resolve_upstream_url(
  target: UpstreamTarget,
  client_path: String,
) -> String {
  let suffix = case string.starts_with(client_path, "/v1") {
    True -> string.drop_start(client_path, 3)
    False -> client_path
  }
  trim_trailing_slash(target.base_url) <> suffix
}

// ── Request body inspection ─────────────────────────────────────

fn stream_field_decoder() -> decode.Decoder(Bool) {
  use stream <- decode.optional_field("stream", False, decode.bool)
  decode.success(stream)
}

fn model_field_decoder() -> decode.Decoder(String) {
  use model <- decode.optional_field("model", "unknown", decode.string)
  decode.success(model)
}

/// Check whether a JSON request body has `"stream": true`.
pub fn is_streaming(body: String) -> Bool {
  case json.parse(from: body, using: stream_field_decoder()) {
    Ok(True) -> True
    _ -> False
  }
}

/// Extract the model name from a JSON request body.
pub fn extract_model(body: String) -> String {
  case json.parse(from: body, using: model_field_decoder()) {
    Ok(model) -> model
    Error(_) -> "unknown"
  }
}

// ── Usage extraction ────────────────────────────────────────────

/// Token usage extracted from a response body or SSE chunk.
///
/// `cached` counts input tokens served from a provider prompt cache; on
/// OpenAI APIs it is reported inside the usage `*_details` object and is
/// already included in `prompt`/`input_tokens`.
pub type Usage {
  Usage(prompt: Option(Int), completion: Option(Int), cached: Option(Int))
}

fn usage_fields_decoder() -> decode.Decoder(Usage) {
  use prompt <- decode.optional_field(
    "prompt_tokens",
    None,
    decode.optional(decode.int),
  )
  use completion <- decode.optional_field(
    "completion_tokens",
    None,
    decode.optional(decode.int),
  )
  use cached <- decode.optional_field(
    "prompt_tokens_details",
    None,
    cached_tokens_details_decoder(),
  )
  decode.success(Usage(prompt:, completion:, cached:))
}

/// Usage fields for the Responses API (incl. Codex), which reports
/// `input_tokens`/`output_tokens` inside `response.usage` on the
/// `response.completed`/`response.incomplete` events.
fn responses_usage_fields_decoder() -> decode.Decoder(Usage) {
  use prompt <- decode.optional_field(
    "input_tokens",
    None,
    decode.optional(decode.int),
  )
  use completion <- decode.optional_field(
    "output_tokens",
    None,
    decode.optional(decode.int),
  )
  use cached <- decode.optional_field(
    "input_tokens_details",
    None,
    cached_tokens_details_decoder(),
  )
  decode.success(Usage(prompt:, completion:, cached:))
}

/// Both OpenAI APIs nest cached input tokens under a details object keyed
/// by `cached_tokens`.
fn cached_tokens_details_decoder() -> decode.Decoder(Option(Int)) {
  use cached_tokens <- decode.optional_field(
    "cached_tokens",
    None,
    decode.optional(decode.int),
  )
  decode.success(cached_tokens)
}

/// Decode usage from either a Chat Completions chunk (`usage.prompt_tokens`)
/// or a Responses API chunk (`response.usage.input_tokens`). Non-usage
/// chunks (content deltas, pings, `[DONE]`) fail both and are ignored.
fn usage_decoder() -> decode.Decoder(Usage) {
  decode.one_of(chat_usage_decoder(), or: [responses_usage_decoder()])
}

fn chat_usage_decoder() -> decode.Decoder(Usage) {
  use usage <- decode.field("usage", usage_fields_decoder())
  decode.success(usage)
}

fn responses_usage_decoder() -> decode.Decoder(Usage) {
  // Drill into `response.usage` (Responses API / Codex) for input/output
  // tokens emitted on response.completed/response.incomplete events.
  decode.at(["response", "usage"], responses_usage_fields_decoder())
}

/// Parse token usage from a non-streaming JSON response body.
pub fn parse_usage(body: String) -> Usage {
  case json.parse(from: body, using: usage_decoder()) {
    Ok(usage) -> usage
    Error(_) -> Usage(None, None, None)
  }
}

/// Parse token usage from one completed SSE frame.
///
/// Network chunks must be framed by `pig_protocol/sse.Decoder` before this
/// function is called, so incomplete UTF-8 or event data is never parsed.
pub fn parse_usage_from_sse(frame: String) -> Usage {
  let data = sse.frame_data(frame)
  case json.parse(from: data, using: usage_decoder()) {
    Ok(usage) -> usage
    Error(_) -> Usage(None, None, None)
  }
}

/// Merge usage extracted from a single chunk into the running stream state.
/// Only overwrites a field when the chunk provides a concrete token count,
/// so non-usage chunks (content deltas, pings, [DONE]) do not erase prior
/// usage.
fn merge_usage(existing: Usage, chunk: Usage) -> Usage {
  Usage(
    prompt: case chunk.prompt {
      Some(tokens) -> Some(tokens)
      None -> existing.prompt
    },
    completion: case chunk.completion {
      Some(tokens) -> Some(tokens)
      None -> existing.completion
    },
    cached: case chunk.cached {
      Some(tokens) -> Some(tokens)
      None -> existing.cached
    },
  )
}

/// Parse usage from a complete SSE event string and merge it into the
/// running stream state. Events without a usage object leave state intact.
fn merge_usage_from_event(existing: Usage, frame: String) -> Usage {
  merge_usage(existing, parse_usage_from_sse(frame))
}

/// Feed one raw network chunk through the byte-safe SSE decoder.
fn push_usage(state: StreamState, chunk: BitArray) -> StreamState {
  case sse.push(state.decoder, chunk) {
    Ok(#(decoder, frames)) -> {
      let usage = list.fold(frames, state.usage, merge_usage_from_event)
      StreamState(..state, decoder:, usage:)
    }
    Error(sse.InvalidUtf8) -> {
      // Forwarding has already succeeded; discard only the unusable decoder
      // state so malformed bytes cannot crash or poison the relay.
      logging.log(
        logging.Warning,
        "proxy: invalid UTF-8 in SSE frame; skipping usage extraction",
      )
      StreamState(..state, decoder: sse.new())
    }
  }
}

/// Finish the decoder at upstream EOF and use any complete trailing frame.
fn finish_usage(state: StreamState) -> Usage {
  case sse.finish(state.decoder) {
    Ok(frames) -> list.fold(frames, state.usage, merge_usage_from_event)
    Error(sse.InvalidUtf8) -> {
      logging.log(
        logging.Warning,
        "proxy: invalid UTF-8 in trailing SSE frame; skipping usage extraction",
      )
      state.usage
    }
  }
}

/// Ensure a request body asks for streaming usage.
///
/// If the body is a JSON object, injects `stream_options.include_usage: true`
/// while preserving any existing fields. On malformed JSON, returns the body
/// unchanged so the upstream can reject it.
@external(erlang, "pig_proxy_json_ffi", "ensure_stream_usage")
pub fn ensure_stream_usage(body: String) -> String

// ── Streaming forward ───────────────────────────────────────────

/// Drive a committed streaming relay onto the client connection.
///
/// Execution has already walked the fallback chain, committed to `target_id`
/// (recording one circuit success), and handed back the relay handle. This
/// starts forwarding to a fresh chunked loop, pipes each `Chunk` to the client while
/// accumulating token usage, and emits the streaming telemetry
/// (`StreamChunk` per chunk; `RequestStop` on completion; `RequestError`
/// on a mid-stream failure) — all attributed to the committed target.
///
/// Retry and fallback are NOT this function's concern: they ended at the
/// commit point (the first byte) inside execution.
pub fn stream_response(
  req: request.Request(mist.Connection),
  handle: transport.StreamHandle,
  target_id: String,
  provider: String,
  model: String,
  status: Int,
  start_time: Int,
) -> response.Response(mist.ResponseData) {
  logging.log(
    logging.Debug,
    "proxy: stream committed to \""
      <> target_id
      <> "\" ("
      <> int_status(status)
      <> ")",
  )

  let initial_response =
    response.new(status)
    |> response.set_header("content-type", "text/event-stream")
    |> response.set_header("cache-control", "no-cache")
    |> response.set_header("connection", "keep-alive")

  mist.chunked(
    req,
    initial_response,
    init: fn(subj) {
      // Tell the relay to start forwarding the body to this loop.
      transport.start(handle, subj)
      StreamState(usage: Usage(None, None, None), decoder: sse.new(), handle:)
    },
    loop: fn(state, message, conn) {
      case message {
        transport.Chunk(data) -> {
          case mist.send_chunk(conn, data) {
            Ok(_) -> {
              telemetry.emit(telemetry.StreamChunk(
                target_id:,
                provider:,
                model:,
                chunk_bytes: bit_array.byte_size(data),
              ))

              let next_state = push_usage(state, data)
              mist.chunk_continue(next_state)
            }
            Error(_) -> {
              let reason = "client disconnected during stream"
              // Telemetry records the disconnect; this log covers the
              // transport action that telemetry does not describe.
              logging.log(logging.Debug, "proxy: cancelling upstream stream")
              transport.cancel(state.handle)
              telemetry.emit(telemetry.RequestError(
                target_id:,
                provider:,
                model:,
                error_type: reason,
              ))
              mist.chunk_stop()
            }
          }
        }
        transport.Done -> {
          logging.log(logging.Debug, "proxy: stream complete")
          let final_usage = finish_usage(state)
          let duration = telemetry.system_time() - start_time
          telemetry.emit(telemetry.RequestStop(
            target_id:,
            provider:,
            model:,
            status:,
            duration_ms: duration,
            input_tokens: final_usage.prompt,
            output_tokens: final_usage.completion,
            cached_input_tokens: final_usage.cached,
          ))
          mist.chunk_stop()
        }
        transport.StreamError(reason) -> {
          telemetry.emit(telemetry.RequestError(
            target_id:,
            provider:,
            model:,
            error_type: reason,
          ))
          // Send an SSE error event so the client can detect the error
          // even though the HTTP status is already committed (required by
          // SSE once the first byte has flowed).
          let sse_error =
            "event: error\ndata: {\"error\":{\"message\":\""
            <> escape_json_string(reason)
            <> "\"}}\n\n"
          let error_data =
            bytes_tree.to_bit_array(bytes_tree.from_string(sse_error))
          let _ = mist.send_chunk(conn, error_data)
          mist.chunk_stop_abnormal(reason)
        }
        transport.Committed(..)
        | transport.Rejected(..)
        | transport.Failed(..) -> mist.chunk_stop()
        transport.Cancelled -> {
          let reason = "stream cancelled"
          telemetry.emit(telemetry.RequestError(
            target_id:,
            provider:,
            model:,
            error_type: reason,
          ))
          mist.chunk_stop()
        }
      }
    },
  )
}

// ── Helpers ─────────────────────────────────────────────────────

fn int_status(n: Int) -> String {
  int.to_string(n)
}

/// Escape a string for safe interpolation into a JSON string literal.
fn escape_json_string(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

/// Convert a hackney sync response into a mist HTTP response.
pub fn sync_response_to_mist(
  resp: hackney.HackneyResponse,
) -> response.Response(mist.ResponseData) {
  case resp {
    hackney.OkResponse(status:, headers:, body:) ->
      render_response(status, headers, body)
    hackney.ErrorResponse(reason:) ->
      response.new(502)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(
          "{\"error\":{\"message\":\"upstream error: "
          <> escape_json_string(reason)
          <> "\"}}",
        )),
      )
  }
}

/// Render an upstream response (status, headers, body) as a mist response,
/// filtering hop-by-hop and connection-nominated headers. Used by the
/// execution path to render a committed outcome.
pub fn render_response(
  status: Int,
  headers: List(#(String, String)),
  body: BitArray,
) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> set_response_headers(headers)
  |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
}

fn set_response_headers(
  resp: response.Response(a),
  headers: List(#(String, String)),
) -> response.Response(a) {
  let nominated = connection_header_tokens(headers)
  let filtered =
    list.filter(headers, fn(h) {
      !is_hop_by_hop_header(h.0)
      && !list.contains(nominated, string.lowercase(h.0))
    })
  list.fold(filtered, resp, fn(acc, h) { response.set_header(acc, h.0, h.1) })
}

/// Header names nominated by the upstream `Connection` header (RFC 7230
/// §6.1). These are per-hop and must not be forwarded to the client;
/// returned lowercased and trimmed for case-insensitive comparison.
fn connection_header_tokens(headers: List(#(String, String))) -> List(String) {
  case list.find(headers, fn(h) { string.lowercase(h.0) == "connection" }) {
    Ok(#(_, value)) ->
      value
      |> string.split(",")
      |> list.map(fn(t) { string.trim(string.lowercase(t)) })
      |> list.filter(fn(t) { t != "" })
    Error(_) -> []
  }
}

/// Headers that must not be forwarded from an upstream response to the
/// client. Hop-by-hop and framing headers are connection-specific and
/// would corrupt the Mist-managed response if copied through.
fn is_hop_by_hop_header(key: String) -> Bool {
  let key_lower = string.lowercase(key)
  list.contains(
    [
      "connection",
      "keep-alive",
      "proxy-authenticate",
      "proxy-authorization",
      "te",
      "trailer",
      "transfer-encoding",
      "upgrade",
      "content-length",
    ],
    key_lower,
  )
}
