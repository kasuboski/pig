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

      case streaming {
        True -> {
          let auth = resolve_auth(primary, state.vault)
          // stream_options.include_usage is a Chat Completions feature;
          // the Responses API emits usage in response.completed regardless.
          let body_with_usage = case path == "/v1/chat/completions" {
            True -> proxy.ensure_stream_usage(body)
            False -> body
          }
          proxy.forward_stream(
            req, primary, auth, method, path, req.headers, body_with_usage,
          )
        }
        False -> {
          let exec =
            execution.executor(hackney.transport(), state.circuit)
            |> maybe_with_vault(state.vault)
            |> execution.with_retries_per_target(state.config.retries_per_target)
          let outcome =
            execution.orchestrate(
              exec,
              execution.ProxyRequest(
                method:,
                path:,
                headers: req.headers,
                body:,
                model:,
              ),
              resolve_chain(state, model),
            )
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

/// Resolve the concrete authentication to apply for a target: the live
/// credential from the vault when one is configured and has an entry,
/// otherwise the target's static `TargetAuth`. A `Codex` target with no
/// live token in the vault resolves to an empty Codex credential and logs
/// a warning (its requests will be unauthenticated) — that is a
/// misconfiguration rather than a normal path.
fn resolve_auth(
  target: UpstreamTarget,
  vault_subject: Option(process.Subject(vault.VaultMsg)),
) -> proxy.ResolvedAuth {
  case vault_subject {
    Some(v) ->
      case vault.get_credential(v, target.id, 2000) {
        vault.CredentialFound(cred) -> credential_to_resolved(cred)
        vault.CredentialNotFound -> static_auth(target)
      }
    None -> static_auth(target)
  }
}

fn credential_to_resolved(cred: vault.Credential) -> proxy.ResolvedAuth {
  case cred {
    vault.ApiKey(key) -> proxy.ApiKey(key)
    vault.CodexToken(token) -> proxy.Codex(token)
  }
}

fn static_auth(target: UpstreamTarget) -> proxy.ResolvedAuth {
  case target.auth {
    config.ApiKey(key) -> proxy.ApiKey(key)
    config.Codex -> {
      logging.log(
        logging.Warning,
        "proxy: Codex target \""
          <> target.id
          <> "\" has no live token in the vault — requests will be"
          <> " unauthenticated",
      )
      proxy.Codex("")
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
