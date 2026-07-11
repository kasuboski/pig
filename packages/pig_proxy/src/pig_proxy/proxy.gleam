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
import gleam/option.{None}
import gleam/string
import logging
import mist
import pig_proxy/config.{type UpstreamTarget}
import pig_proxy/hackney
import pig_proxy/telemetry

/// Messages sent from the streaming relay to the mist chunked loop.
pub type ProxyMessage {
  Chunk(BitArray)
  StreamDone
  StreamError(String)
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
pub fn build_upstream_headers(
  client_headers: List(#(String, String)),
  target: UpstreamTarget,
  streaming: Bool,
) -> List(#(String, String)) {
  let accept = case streaming {
    True -> "text/event-stream"
    False -> "application/json"
  }
  scrub_headers(client_headers)
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
/// includes `/v1`. We strip the leading `/v1` from the client path and
/// append the remainder to the target base_url.
pub fn resolve_upstream_url(target: UpstreamTarget, client_path: String) -> String {
  let suffix = case string.split(client_path, "/v1") {
    [_, rest] -> rest
    _ -> client_path
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
      let _relay =
        hackney.stream_request(
          method,
          url,
          headers,
          body,
          fn(chunk) { process.send(subj, Chunk(chunk)) },
          fn(_) { process.send(subj, StreamDone) },
          fn(reason) { process.send(subj, StreamError(reason)) },
        )
      Nil
    },
    loop: fn(_state, message, conn) {
      case message {
        Chunk(data) -> {
          case mist.send_chunk(conn, data) {
            Ok(_) -> {
              telemetry.emit(telemetry.StreamChunk(
                target_id: target_id,
                model: model,
                chunk_bytes: bit_array.byte_size(data),
              ))
              mist.chunk_continue(Nil)
            }
            Error(_) -> {
              logging.log(
                logging.Debug,
                "proxy: client disconnected during stream, stopping relay",
              )
              mist.chunk_stop()
            }
          }
        }
        StreamDone -> {
          logging.log(logging.Debug, "proxy: stream complete")
          let duration = telemetry.system_time() - start_time
          telemetry.emit(telemetry.RequestStop(
            target_id: target_id,
            model: model,
            status: 200,
            duration_ms: duration,
            input_tokens: None,
            output_tokens: None,
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
  list.fold(headers, resp, fn(acc, h) {
    response.set_header(acc, h.0, h.1)
  })
}
