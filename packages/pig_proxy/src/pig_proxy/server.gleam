//// The mist HTTP server: request body reading, route dispatch, and
//// response assembly.
////
//// Routes:
////   POST /v1/chat/completions  — proxy to upstream (streaming or sync)
////   POST /v1/responses         — proxy to upstream (Codex Responses)
////   GET  /health               — liveness probe
////   GET  /metrics              — Prometheus metrics (Phase 4)
////   *    /                     — 404

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import logging
import mist
import pig_proxy/config.{type ProxyConfig, type UpstreamTarget}
import pig_proxy/hackney
import pig_proxy/metrics
import pig_proxy/metrics_endpoint
import pig_proxy/model_catalog
import pig_proxy/proxy
import pig_proxy/retry
import pig_proxy/routes.{type VirtualRoute}
import pig_proxy/telemetry
import pig_proxy/vault

/// Maximum request body size (10 MB).
const max_body_bytes = 10_485_760

/// Default upstream timeout for non-streaming requests (120 s).
const default_upstream_timeout_ms = 120_000

/// Base delay for retry backoff (1 second).
const retry_base_ms = 1000

/// Maximum retry backoff cap (30 seconds).
const retry_max_ms = 30_000

/// Server state captured in the handler closure.
pub type ServerState {
  ServerState(
    config: ProxyConfig,
    routes: List(VirtualRoute),
    metrics: Option(process.Subject(metrics.MetricsMsg)),
    catalog: Option(process.Subject(model_catalog.CatalogMsg)),
    /// Credential vault. When present, the live credential for a target
    /// (kept fresh by e.g. `pig_proxy/codex_refresh`) overrides the
    /// static `api_key`/`codex_token` baked into `config` at startup —
    /// see `apply_live_credential`.
    vault: Option(process.Subject(vault.VaultMsg)),
  )
}

/// Start the proxy server with the given state.
/// Returns after mist starts and logs the listening address.
/// The caller is responsible for keeping the process alive (e.g. via
/// `process.sleep_forever()` in `main`).
pub fn start(state: ServerState) -> Nil {
  logging.configure()
  hackney.ensure_started()
  let handler = fn(req) { handle_request(req, state) }

  let assert Ok(_) =
    handler
    |> mist.new
    |> mist.port(state.config.port)
    |> mist.start

  logging.log(
    logging.Info,
    "pig_proxy listening on :" <> int.to_string(state.config.port),
  )
}

/// The main request handler.
fn handle_request(
  req: request.Request(mist.Connection),
  state: ServerState,
) -> response.Response(mist.ResponseData) {
  case req.method, request.path_segments(req) {
    http.Get, ["health"] -> health_response()

    http.Get, ["metrics"] -> metrics_response(state)

    http.Post, ["v1", "chat", "completions"] ->
      proxy_request(req, state, "/v1/chat/completions")

    http.Post, ["v1", "responses"] ->
      proxy_request(req, state, "/v1/responses")

    _, _ -> not_found_response()
  }
}

/// Proxy a request to the upstream target.
fn proxy_request(
  req: request.Request(mist.Connection),
  state: ServerState,
  path: String,
) -> response.Response(mist.ResponseData) {
  case mist.read_body(req, max_body_bytes) {
    Error(_) -> bad_request_response("request body too large or malformed")
    Ok(body_req) -> {
      let body = bit_array_to_string(body_req.body)
      let model = proxy.extract_model(body)
      let target = select_target(state, model) |> apply_live_credential(state)
      let method = method_to_string(req.method)
      let streaming = proxy.is_streaming(body)
      let provider = config.provider_string(target)

      telemetry.emit(telemetry.RequestStart(
        target_id: target.id,
        provider:,
        model:,
        streaming:,
      ))

      let start_time = telemetry.system_time()

      case streaming {
        True -> {
          // stream_options.include_usage is a Chat Completions feature;
          // the Responses API emits usage in response.completed regardless.
          let body_with_usage = case path == "/v1/chat/completions" {
            True -> proxy.ensure_stream_usage(body)
            False -> body
          }
          proxy.forward_stream(
            req, target, method, path, req.headers, body_with_usage,
          )
        }
        False -> {
          let resp =
            forward_with_retry(
              state.config,
              target,
              method,
              path,
              req.headers,
              body,
              0,
            )
          let duration = telemetry.system_time() - start_time

          case resp {
            hackney.OkResponse(status:, body: resp_body, ..) -> {
              let usage = proxy.parse_usage(bit_array_to_string(resp_body))
              telemetry.emit(telemetry.RequestStop(
                target_id: target.id,
                provider:,
                model:,
                status:,
                duration_ms: duration,
                input_tokens: usage.prompt,
                output_tokens: usage.completion,
              ))
            }
            hackney.ErrorResponse(reason:) ->
              telemetry.emit(telemetry.RequestError(
                target_id: target.id,
                provider:,
                model:,
                error_type: reason,
              ))
          }

          proxy.sync_response_to_mist(resp)
        }
      }
    }
  }
}

/// Retry loop for non-streaming requests.
/// Retries on transient HTTP status codes (429, 500, 502, 503, 504)
/// and network errors, with exponential backoff and jitter.
fn forward_with_retry(
  config: ProxyConfig,
  target: UpstreamTarget,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: String,
  attempt: Int,
) -> hackney.HackneyResponse {
  let resp =
    proxy.forward_sync(target, method, path, headers, body, default_upstream_timeout_ms)

  case should_retry(resp, attempt, config.max_retries) {
    True -> {
      let retry_after = extract_retry_after(resp)
      let delay =
        retry.retry_delay(attempt, retry_base_ms, retry_max_ms, retry_after)
      logging.log(
        logging.Debug,
        "proxy: retrying attempt " <> int.to_string(attempt + 1) <> " after "
          <> int.to_string(delay)
          <> "ms",
      )
      process.sleep(delay)
      forward_with_retry(config, target, method, path, headers, body, attempt + 1)
    }
    False -> resp
  }
}

/// Whether a response warrants a retry.
fn should_retry(
  resp: hackney.HackneyResponse,
  attempt: Int,
  max_retries: Int,
) -> Bool {
  case attempt >= max_retries {
    True -> False
    False ->
      case resp {
        hackney.OkResponse(status:, ..) -> retry.is_retryable_status(status)
        hackney.ErrorResponse(..) -> True
      }
  }
}

/// Extract the Retry-After header value from a hackney response, if present.
/// HTTP headers are case-insensitive, so we compare lowercased.
fn extract_retry_after(
  resp: hackney.HackneyResponse,
) -> Option(String) {
  case resp {
    hackney.OkResponse(headers:, ..) ->
      case list.find(headers, fn(h) {
        string.lowercase(h.0) == "retry-after"
      }) {
        Ok(#(_, value)) -> Some(value)
        Error(_) -> None
      }
    hackney.ErrorResponse(..) -> None
  }
}

/// Select the upstream target using route resolution.
/// Falls back to the first configured target if no route matches.
fn select_target(state: ServerState, model: String) -> UpstreamTarget {
  let resolved = routes.resolve(state.config, state.routes, model)
  case routes.primary_target(resolved) {
    Some(target) -> target
    None ->
      case list.first(state.config.targets) {
        Ok(target) -> target
        Error(_) ->
          panic as "no upstream targets configured — add at least one target"
      }
  }
}

/// Overlay the live credential from the vault onto the target, when a
/// vault is configured. A `vault.CodexToken` becomes the target's
/// `codex_token` (and its `api_key`, so the Bearer header matches what
/// the Codex Responses endpoint expects); a `vault.ApiKey` becomes the
/// target's `api_key`. If the vault has no entry for this target, the
/// static config target is returned unchanged.
fn apply_live_credential(
  target: UpstreamTarget,
  state: ServerState,
) -> UpstreamTarget {
  case state.vault {
    Some(v) ->
      case vault.get_credential(v, target.id, 2000) {
        vault.CredentialFound(vault.CodexToken(token)) ->
          config.UpstreamTarget(
            ..target,
            api_key: token,
            codex_token: Some(token),
          )
        vault.CredentialFound(vault.ApiKey(key)) ->
          config.UpstreamTarget(..target, api_key: key, codex_token: None)
        vault.CredentialNotFound -> target
      }
    None -> target
  }
}

// ── Static responses ────────────────────────────────────────────

fn health_response() -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(
    bytes_tree.from_string("{\"status\":\"ok\"}"),
  ))
}

fn metrics_response(
  state: ServerState,
) -> response.Response(mist.ResponseData) {
  case state.metrics {
    Some(metrics_subject) -> {
      let snapshot = metrics.get_snapshot(metrics_subject)
      let catalog = case state.catalog {
        Some(catalog_subject) -> model_catalog.snapshot(catalog_subject)
        None -> model_catalog.empty()
      }
      metrics_endpoint.response(snapshot, catalog)
    }
    None ->
      response.new(503)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(mist.Bytes(
        bytes_tree.from_string("metrics aggregator not started"),
      ))
  }
}

fn not_found_response() -> response.Response(mist.ResponseData) {
  response.new(404)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(
    bytes_tree.from_string("{\"error\":{\"message\":\"not found\"}}"),
  ))
}

fn bad_request_response(
  detail: String,
) -> response.Response(mist.ResponseData) {
  response.new(400)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(
    bytes_tree.from_string(
      "{\"error\":{\"message\":\"" <> detail <> "\"}}",
    ),
  ))
}

// ── Conversion helpers ──────────────────────────────────────────

fn bit_array_to_string(data: BitArray) -> String {
  case bit_array.to_string(data) {
    Ok(s) -> s
    Error(_) -> {
      logging.log(
        logging.Warning,
        "server: request body is not valid UTF-8, treating as empty",
      )
      ""
    }
  }
}

fn method_to_string(method: http.Method) -> String {
  case method {
    http.Get -> "GET"
    http.Post -> "POST"
    http.Put -> "PUT"
    http.Delete -> "DELETE"
    http.Patch -> "PATCH"
    http.Head -> "HEAD"
    http.Options -> "OPTIONS"
    http.Connect -> "CONNECT"
    http.Trace -> "TRACE"
    http.Other(m) -> m
  }
}
