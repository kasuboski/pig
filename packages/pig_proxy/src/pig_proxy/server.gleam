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
import logging
import mist
import pig_proxy/circuit_actor
import pig_proxy/config.{type ProxyConfig, type UpstreamTarget}
import pig_proxy/execution
import pig_proxy/hackney
import pig_proxy/metrics
import pig_proxy/metrics_endpoint
import pig_proxy/model_catalog
import pig_proxy/proxy
import pig_proxy/routes.{type VirtualRoute}
import pig_proxy/telemetry
import pig_proxy/vault

/// Maximum request body size (10 MB).
const max_body_bytes = 10_485_760

/// Server state captured in the handler closure.
pub type ServerState {
  ServerState(
    config: ProxyConfig,
    routes: List(VirtualRoute),
    metrics: Option(process.Subject(metrics.MetricsMsg)),
    catalog: Option(process.Subject(model_catalog.CatalogMsg)),
    /// Credential vault. When present, the live credential for a target
    /// (kept fresh by `pig_proxy/codex_refresh`) overrides the static
    /// `TargetAuth` baked into `config` at startup.
    vault: Option(process.Subject(vault.VaultMsg)),
    /// Per-target circuit breaker. When present, request execution
    /// consults it for admission and records one failure per exhausted
    /// retry budget.
    circuit: Option(process.Subject(circuit_actor.CircuitMsg)),
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
      let streaming = proxy.is_streaming(body)
      let method = method_to_string(req.method)
      let primary = select_target(state, model)
      let provider = config.provider_string(primary)

      telemetry.emit(telemetry.RequestStart(
        target_id: primary.id,
        provider:,
        model:,
        streaming:,
      ))

      let exec =
        execution.executor(hackney.transport(), state.circuit)
        |> maybe_with_vault(state.vault)
        |> execution.with_retries_per_target(state.config.retries_per_target)
      let request =
        execution.ProxyRequest(
          method:,
          path:,
          headers: req.headers,
          body:,
          model:,
        )
      let chain = resolve_chain(state, model)

      case streaming {
        True -> execute_stream(req, exec, request, chain, path, model)
        False -> {
          let outcome = execution.orchestrate(exec, request, chain)
          emit_outcome_telemetry(outcome, model)
          render_outcome(outcome)
        }
      }
    }
  }
}

/// Resolve the ordered fallback chain for a model from routing. Falls
/// back to all configured targets when no route matches.
fn resolve_chain(state: ServerState, model: String) -> execution.FallbackChain {
  let resolved = routes.resolve(state.config, state.routes, model)
  let targets = case resolved {
    routes.ResolvedRoute(targets:) -> targets
    routes.NoTargets -> state.config.targets
  }
  execution.FallbackChain(targets:)
}

/// Apply the vault to an executor when one is configured.
fn maybe_with_vault(
  exec: execution.Executor,
  vault: Option(process.Subject(vault.VaultMsg)),
) -> execution.Executor {
  case vault {
    Some(v) -> execution.with_vault(exec, v)
    None -> exec
  }
}

/// Emit exactly one terminal telemetry event, attributed to the target
/// that produced the committed outcome (or the last attempted target).
fn emit_outcome_telemetry(outcome: execution.Outcome, model: String) -> Nil {
  case outcome {
    execution.Committed(
      target_id:, provider:, status:, usage:, duration_ms:, ..
    ) ->
      telemetry.emit(telemetry.RequestStop(
        target_id:, provider:, model:, status:, duration_ms:,
        input_tokens: usage.prompt,
        output_tokens: usage.completion,
      ))
    execution.Exhausted(target_id:, provider:, reason:, ..) ->
      telemetry.emit(telemetry.RequestError(
        target_id: option.unwrap(target_id, ""),
        provider:, model:, error_type: reason,
      ))
    execution.NoTargets(..) ->
      telemetry.emit(telemetry.RequestError(
        target_id: "",
        provider: "",
        model:, error_type: "no upstream targets available",
      ))
    // A streaming commit is driven onto the connection by `execute_stream`;
    // its terminal telemetry is emitted by the chunked loop. Reaching here
    // would mean a commit was never driven — emit nothing.
    execution.CommittedStream(..) -> Nil
  }
}

/// Render an execution outcome as a mist response.
fn render_outcome(outcome: execution.Outcome) -> response.Response(mist.ResponseData) {
  case outcome {
    execution.Committed(status:, headers:, body:, ..) ->
      proxy.render_response(status, headers, body)
    execution.Exhausted(reason:, ..) ->
      response.new(502)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(mist.Bytes(
        bytes_tree.from_string("upstream error: " <> reason),
      ))
    execution.NoTargets(..) ->
      response.new(503)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(mist.Bytes(
        bytes_tree.from_string("no upstream targets available"),
      ))
    // Unreachable in practice: a streaming commit is driven by
    // `execute_stream`, never rendered here. Defensive fallback.
    execution.CommittedStream(..) ->
      response.new(500)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(mist.Bytes(
        bytes_tree.from_string("streaming response was not driven onto the connection"),
      ))
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

/// Execute a streaming request through the execution seam, then drive the
/// committed relay onto the client connection. Retry, fallback, and circuit
/// admission apply up to the first byte; once committed, the chunked loop
/// owns the rest and emits the terminal streaming telemetry.
fn execute_stream(
  req: request.Request(mist.Connection),
  exec: execution.Executor,
  request: execution.ProxyRequest,
  chain: execution.FallbackChain,
  path: String,
  model: String,
) -> response.Response(mist.ResponseData) {
  // stream_options.include_usage is a Chat Completions feature; the
  // Responses API emits usage in response.completed regardless.
  let body = case path == "/v1/chat/completions" {
    True -> proxy.ensure_stream_usage(request.body)
    False -> request.body
  }
  let stream_request = execution.ProxyRequest(..request, body:)

  let start_time = telemetry.system_time()
  let outcome = execution.orchestrate_stream(exec, stream_request, chain)
  case outcome {
    execution.CommittedStream(target_id:, provider:, status:, run:) -> {
      let assert Ok(relay) = process.subject_owner(run)
      proxy.stream_response(
        req, run, relay, target_id, provider, model, status, start_time,
      )
    }
    execution.Committed(..) | execution.Exhausted(..) | execution.NoTargets(..) -> {
      emit_outcome_telemetry(outcome, model)
      render_outcome(outcome)
    }
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
