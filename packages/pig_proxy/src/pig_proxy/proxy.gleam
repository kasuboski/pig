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
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import logging
import mist
import pig_protocol/auth
import pig_proxy/config.{type UpstreamTarget}
import pig_proxy/hackney
import pig_proxy/telemetry

/// Messages sent from the streaming relay to the mist chunked loop.
pub type ProxyMessage {
  Chunk(BitArray)
  StreamDone
  StreamError(String)
}

/// State held by the streaming chunked loop: accumulated token usage, a
/// buffer of incomplete SSE data across network fragments, and the upstream
/// relay PID so it can be killed if the client disconnects.
type StreamState {
  StreamState(usage: Usage, buffer: String, relay: process.Pid)
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

/// Build the full header list for an upstream request: scrubbed client
/// headers plus injected auth and JSON content headers.
///
/// Targets with a Codex OAuth token (`target.codex_token`) get the Codex
/// Responses API header set — `chatgpt-account-id` derived from the JWT,
/// plus the required `OpenAI-Beta`/`originator` headers — instead of a
/// plain Bearer key. If the token can't be decoded (e.g. malformed JWT),
/// this falls back to plain Bearer injection and logs a warning rather
/// than failing the request outright.
pub fn build_upstream_headers(
  client_headers: List(#(String, String)),
  target: UpstreamTarget,
  streaming: Bool,
) -> List(#(String, String)) {
  let scrubbed = scrub_headers(client_headers)
  case target.codex_token {
    Some(token) ->
      case auth.headers(auth.CodexOAuth(token, target.base_url), streaming) {
        Ok(codex_headers) -> list.append(scrubbed, codex_headers)
        Error(_) -> {
          logging.log(
            logging.Warning,
            "proxy: failed to derive chatgpt-account-id for target \""
              <> target.id
              <> "\" — falling back to plain bearer injection",
          )
          bearer_headers(scrubbed, target, streaming)
        }
      }
    None -> bearer_headers(scrubbed, target, streaming)
  }
}

fn bearer_headers(
  scrubbed_headers: List(#(String, String)),
  target: UpstreamTarget,
  streaming: Bool,
) -> List(#(String, String)) {
  let accept = case streaming {
    True -> "text/event-stream"
    False -> "application/json"
  }
  scrubbed_headers
  |> inject_api_key(target.api_key)
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
pub fn resolve_upstream_url(target: UpstreamTarget, client_path: String) -> String {
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
pub type Usage {
  Usage(prompt: Option(Int), completion: Option(Int))
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
  decode.success(Usage(prompt:, completion:))
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
  decode.success(Usage(prompt:, completion:))
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
    Error(_) -> Usage(None, None)
  }
}

/// Parse token usage from an SSE chunk string.
///
/// Scans `data:` lines and returns the last valid usage object found.
pub fn parse_usage_from_sse(chunk: String) -> Usage {
  chunk
  |> string.split("\n")
  |> list.filter_map(fn(line) {
    case string.starts_with(line, "data: ") {
      True -> {
        let json_str = string.drop_start(line, 6)
        case json.parse(from: json_str, using: usage_decoder()) {
          Ok(usage) -> Ok(usage)
          Error(_) -> Error(Nil)
        }
      }
      False -> Error(Nil)
    }
  })
  |> list.last
  |> option.from_result
  |> option.unwrap(Usage(None, None))
}

/// Split a raw SSE buffer into complete events and an incomplete trailing
/// fragment. Events are delimited by a blank line (`\n\n`). Any text after
/// the last `\n\n` is returned as the leftover buffer for the next chunk.
fn split_sse_events(buffer: String) -> #(List(String), String) {
  // Normalise CRLF to LF so CRLF-delimited SSE streams (valid per the
  // SSE spec) split the same way as LF-delimited ones. The buffer is
  // used only for usage parsing, so normalising never affects the bytes
  // forwarded to the client.
  let buffer = string.replace(buffer, "\r\n", "\n")
  case string.split_once(buffer, "\n\n") {
    Ok(#(event, rest)) -> {
      let #(events, leftover) = split_sse_events(rest)
      #([event, ..events], leftover)
    }
    Error(_) -> #([], buffer)
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
  )
}

/// Parse usage from a complete SSE event string and merge it into the
/// running stream state. Events without a usage object leave state intact.
fn merge_usage_from_event(existing: Usage, event: String) -> Usage {
  merge_usage(existing, parse_usage_from_sse(event))
}

/// Ensure a request body asks for streaming usage.
///
/// If the body is a JSON object, injects `stream_options.include_usage: true`
/// while preserving any existing fields. On malformed JSON, returns the body
/// unchanged so the upstream can reject it.
@external(erlang, "pig_proxy_json_ffi", "ensure_stream_usage")
pub fn ensure_stream_usage(body: String) -> String

// ── Non-streaming forward ───────────────────────────────────────

/// Forward a non-streaming request to the upstream target and return
/// the raw hackney response.
pub fn forward_sync(
  target: UpstreamTarget,
  method: String,
  path: String,
  client_headers: List(#(String, String)),
  body: String,
  timeout_ms: Int,
) -> hackney.HackneyResponse {
  let url = resolve_upstream_url(target, path)
  let headers = build_upstream_headers(client_headers, target, False)
  logging.log(logging.Debug, "proxy: sync " <> method <> " " <> url)
  hackney.sync_request(method, url, headers, body, timeout_ms)
}

// ── Streaming forward ───────────────────────────────────────────

/// Forward a streaming request to the upstream target, piping SSE chunks
/// back to the client via `mist.chunked`.
///
/// A relay process is spawned inside the chunked `init` callback. The relay
/// uses hackney's async streaming to receive upstream chunks and forwards
/// them as `ProxyMessage` values to the chunked loop's subject. The loop
/// then writes each chunk to the client connection via `mist.send_chunk`.
///
/// Telemetry events (StreamChunk, RequestStop, RequestError) are emitted
/// from within the loop so streaming requests are visible to the metrics
/// aggregator.
pub fn forward_stream(
  req: request.Request(mist.Connection),
  target: UpstreamTarget,
  method: String,
  path: String,
  client_headers: List(#(String, String)),
  body: String,
) -> response.Response(mist.ResponseData) {
  let url = resolve_upstream_url(target, path)
  let headers = build_upstream_headers(client_headers, target, True)
  let model = extract_model(body)
  let target_id = target.id
  let provider = config.provider_string(target)
  logging.log(logging.Debug, "proxy: stream " <> method <> " " <> url)

  let initial_response =
    response.new(200)
    |> response.set_header("content-type", "text/event-stream")
    |> response.set_header("cache-control", "no-cache")
    |> response.set_header("connection", "keep-alive")

  let start_time = telemetry.system_time()

  mist.chunked(
    req,
    initial_response,
    init: fn(subj) {
      let relay =
        hackney.stream_request(
          method,
          url,
          headers,
          body,
          fn(chunk) { process.send(subj, Chunk(chunk)) },
          fn(_) { process.send(subj, StreamDone) },
          fn(reason) { process.send(subj, StreamError(reason)) },
        )
      StreamState(usage: Usage(None, None), buffer: "", relay: relay)
    },
    loop: fn(state, message, conn) {
      case message {
        Chunk(data) -> {
          case mist.send_chunk(conn, data) {
            Ok(_) -> {
              telemetry.emit(telemetry.StreamChunk(
                target_id: target_id,
                provider: provider,
                model: model,
                chunk_bytes: bit_array.byte_size(data),
              ))

              let new_buffer = case bit_array.to_string(data) {
                Ok(text) -> state.buffer <> text
                Error(_) -> state.buffer
              }
              let #(events, leftover) = split_sse_events(new_buffer)
              let new_usage =
                list.fold(events, state.usage, merge_usage_from_event)

              mist.chunk_continue(StreamState(
                usage: new_usage,
                buffer: leftover,
                relay: state.relay,
              ))
            }
            Error(_) -> {
              logging.log(
                logging.Debug,
                "proxy: client disconnected during stream, stopping relay",
              )
              process.kill(state.relay)
              mist.chunk_stop()
            }
          }
        }
        StreamDone -> {
          logging.log(logging.Debug, "proxy: stream complete")
          // Flush any trailing event that never received a final delimiter.
          let final_usage = case state.buffer {
            "" -> state.usage
            remaining -> merge_usage_from_event(state.usage, remaining)
          }
          let duration = telemetry.system_time() - start_time
          telemetry.emit(telemetry.RequestStop(
            target_id: target_id,
            provider: provider,
            model: model,
            status: 200,
            duration_ms: duration,
            input_tokens: final_usage.prompt,
            output_tokens: final_usage.completion,
          ))
          mist.chunk_stop()
        }
        StreamError(reason) -> {
          logging.log(
            logging.Error,
            "proxy: stream error: " <> reason,
          )
          telemetry.emit(telemetry.RequestError(
            target_id: target_id,
            provider: provider,
            model: model,
            error_type: reason,
          ))
          // Send an SSE error event so the client can detect the error
          // even though the HTTP status is already 200 (required by SSE).
          let sse_error =
            "event: error\ndata: {\"error\":{\"message\":\""
            <> escape_json_string(reason)
            <> "\"}}\n\n"
          let error_data = bytes_tree.to_bit_array(
            bytes_tree.from_string(sse_error),
          )
          let _ = mist.send_chunk(conn, error_data)
          mist.chunk_stop_abnormal(reason)
        }
      }
    },
  )
}

// ── Helpers ─────────────────────────────────────────────────────

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
      response.new(status)
      |> set_response_headers(headers)
      |> response.set_body(mist.Bytes(bytes_tree.from_bit_array(body)))
    hackney.ErrorResponse(reason:) ->
      response.new(502)
      |> response.set_header("content-type", "application/json")
      |> response.set_body(mist.Bytes(
        bytes_tree.from_string(
          "{\"error\":{\"message\":\"upstream error: "
            <> escape_json_string(reason)
            <> "\"}}",
        ),
      ))
  }
}

fn set_response_headers(
  resp: response.Response(a),
  headers: List(#(String, String)),
) -> response.Response(a) {
  let nominated = connection_header_tokens(headers)
  let filtered = list.filter(headers, fn(h) {
    !is_hop_by_hop_header(h.0) && !list.contains(nominated, string.lowercase(h.0))
  })
  list.fold(filtered, resp, fn(acc, h) {
    response.set_header(acc, h.0, h.1)
  })
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
