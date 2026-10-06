//// The mist HTTP server: request body reading, route dispatch, and
//// response assembly.
////
//// Routes:
////   POST /v1/chat/completions  — proxy to upstream (streaming or sync)
////   POST /v1/responses         — proxy to upstream (Codex Responses)
////   GET  /v1/models            — configured OpenAI-compatible model list
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
import otel/context
import pig_otel
import pig_proxy/circuit_actor
import pig_proxy/config.{type ProxyConfig}
import pig_proxy/execution
import pig_proxy/hackney
import pig_proxy/metrics
import pig_proxy/metrics_endpoint
import pig_proxy/model_catalog
import pig_proxy/models_endpoint
import pig_proxy/proxy
import pig_proxy/routes
import pig_proxy/telemetry
import pig_proxy/trace_metadata
import pig_proxy/tracing
import pig_proxy/vault

/// Maximum request body size (10 MB).
const max_body_bytes = 10_485_760

/// Server state captured in the handler closure.
pub type ServerState {
  ServerState(
    /// Managed runtime root, stopped by `runtime.stop`. `None` means the host
    /// owns external supervision and is responsible for lifecycle cleanup.
    supervisor: Option(process.Pid),
    config: ProxyConfig,
    emitter: telemetry.Emitter,
    owners: tracing.Owners,
    /// Per-target circuit breaker, addressed by name (supervised). Resolved
    /// per request so a restarted breaker is reached transparently.
    circuit: process.Name(circuit_actor.CircuitMsg),
    /// Model catalog, addressed by name (supervised); used by /metrics.
    catalog: process.Name(model_catalog.CatalogMsg),
    /// Metrics aggregator, addressed by name (supervised); used by /metrics.
    metrics: process.Name(metrics.MetricsMsg),
    /// Credential vault, addressed by name (supervised under the cred
    /// rest_for_one sub-tree). Resolved per request so a restarted vault is
    /// reached transparently; `None` when no Codex target is configured.
    vault: Option(process.Name(vault.VaultMsg)),
  )
}

/// Start the proxy server with the given state.
/// Returns after mist starts and logs the listening address.
/// The caller is responsible for keeping the process alive (e.g. via
/// `process.sleep_forever()` in `main`).
pub fn start(state: ServerState) -> Nil {
  let assert Ok(_) = start_managed(state)
  Nil
}

/// Handle to a listener started by `start_managed`.
pub opaque type Listener {
  Listener(process.Pid)
}

/// Start ingress and retain its supervisor PID so a host can stop listening
/// before stopping the managed runtime.
pub fn start_managed(state: ServerState) -> Result(Listener, String) {
  logging.configure()
  hackney.ensure_started()
  let handler = fn(req) { handle_request(req, state) }
  case
    handler
    |> mist.new
    |> mist.bind(state.config.bind)
    |> mist.port(state.config.port)
    |> mist.start
  {
    Ok(started) -> {
      logging.log(
        logging.Info,
        "pig_proxy listening on "
          <> state.config.bind
          <> ":"
          <> int.to_string(state.config.port),
      )
      Ok(Listener(started.pid))
    }
    Error(_) -> Error("failed to start HTTP listener")
  }
}

/// Stop managed ingress synchronously, force-stopping a stuck listener after
/// five seconds. This does not claim connection drain or wire delivery.
pub fn stop_managed(listener: Listener) -> Nil {
  let Listener(pid) = listener
  stop_listener(pid)
}

@external(erlang, "pig_proxy_server_ffi", "stop_listener")
fn stop_listener(pid: process.Pid) -> Nil

/// The main request handler.
fn handle_request(
  req: request.Request(mist.Connection),
  state: ServerState,
) -> response.Response(mist.ResponseData) {
  case req.method, request.path_segments(req) {
    http.Get, ["health"] -> health_response()

    http.Get, ["metrics"] -> metrics_response(state)

    http.Get, ["v1", "models"] -> models_endpoint.response(state.config)

    http.Post, ["v1", "chat", "completions"] ->
      proxy_request(req, state, "/v1/chat/completions")

    http.Post, ["v1", "responses"] -> proxy_request(req, state, "/v1/responses")

    _, _ -> not_found_response()
  }
}

/// Proxy a request to the upstream target.
fn proxy_request(
  req: request.Request(mist.Connection),
  state: ServerState,
  path: String,
) -> response.Response(mist.ResponseData) {
  let owner =
    tracing.register_with_policy(
      state.owners,
      state.config.tracing,
      req.headers,
      path,
    )
  let assert tracing.Current(server_context) =
    tracing.call(owner, tracing.ServerContext)
  use <- context.with_context(server_context)
  case mist.read_body(req, max_body_bytes) {
    Error(_) -> {
      let rendered = bad_request_response("request body too large or malformed")
      let _ =
        tracing.call(
          owner,
          tracing.LogicalTerminal(
            pig_otel.Failed("invalid_request"),
            trace_metadata.empty(),
            400,
          ),
        )
      let _ =
        tracing.call(
          owner,
          tracing.Downstream(pig_otel.Failed("invalid_request")),
        )
      rendered
    }
    Ok(body_req) -> {
      let body = bit_array_to_string(body_req.body)
      case proxy.extract_model(body) {
        Error(_) -> invalid_model_response(owner)
        Ok(model) -> proxy_valid_request(req, state, path, owner, body, model)
      }
    }
  }
}

fn invalid_model_response(
  owner: tracing.Owner,
) -> response.Response(mist.ResponseData) {
  let failed = pig_otel.Failed("invalid_request")
  let _ =
    tracing.call(
      owner,
      tracing.LogicalTerminal(failed, trace_metadata.empty(), 400),
    )
  let _ = tracing.call(owner, tracing.Downstream(failed))
  bad_request_response("request body must contain a non-blank string model")
}

fn proxy_valid_request(
  req: request.Request(mist.Connection),
  state: ServerState,
  path: String,
  owner: tracing.Owner,
  body: String,
  model: String,
) -> response.Response(mist.ResponseData) {
  let streaming = proxy.is_streaming(body)
  let method = method_to_string(req.method)
  telemetry.emit_scoped(
    state.emitter,
    telemetry.RequestStart(model:, streaming:),
  )
  let exec =
    execution.executor(hackney.transport(), resolve_named(state.circuit))
    |> maybe_with_vault(state.vault)
    |> execution.with_retries_per_target(state.config.retries_per_target)
    |> execution.with_tracing(owner)
  let request =
    execution.ProxyRequest(method:, path:, headers: req.headers, body:, model:)
  let api = case path {
    "/v1/responses" -> pig_otel.Responses
    _ -> pig_otel.ChatCompletions
  }
  let chain = resolve_chain(state, api, model)
  let pricing_catalog = model_catalog.cached(state.catalog)
  let pricing =
    model_catalog.pin(
      pricing_catalog,
      list.filter_map(chain.targets, fn(target) {
        case target.provider {
          Some(provider) -> Ok(#(provider, model))
          None -> Error(Nil)
        }
      }),
    )
  let assert tracing.Current(ctx) =
    tracing.call(owner, tracing.BeginInference(api, None, model, Some(pricing)))
  context.with_context(ctx, fn() {
    case streaming {
      True ->
        execute_stream(
          req,
          exec,
          request,
          chain,
          path,
          model,
          owner,
          state.emitter,
        )
      False -> {
        let outcome = execution.orchestrate(exec, request, chain)
        emit_outcome_telemetry(outcome, model, state.emitter)
        let rendered = render_outcome(outcome)
        finish_buffered(owner, api, outcome, False)
        rendered
      }
    }
  })
}

/// Resolve the configured targets for this API/model without fallback.
fn resolve_chain(
  state: ServerState,
  api: pig_otel.Api,
  model: String,
) -> execution.FallbackChain {
  execution.FallbackChain(targets: routes.resolve_request(
    state.config,
    api,
    model,
  ))
}

/// Apply the vault to an executor when one is configured (and currently
/// registered; degrades to static auth during the brief vault restart window).
fn maybe_with_vault(
  exec: execution.Executor,
  vault: Option(process.Name(vault.VaultMsg)),
) -> execution.Executor {
  case vault {
    Some(name) ->
      case resolve_named(name) {
        Some(v) -> execution.with_vault(exec, v)
        None -> exec
      }
    None -> exec
  }
}

/// Resolve a named supervised actor to its current subject, or `None` if it
/// is briefly unregistered (mid-restart) — callers degrade gracefully. This
/// is what makes a restarted actor transparent: the supervisor re-registers
/// the name, and the next request reaches the new process.
fn resolve_named(name: process.Name(a)) -> Option(process.Subject(a)) {
  case process.named(name) {
    Ok(_) -> Some(process.named_subject(name))
    Error(_) -> None
  }
}

/// Emit exactly one terminal telemetry event, attributed to the target
/// that produced the committed outcome (or the last attempted target).
fn emit_outcome_telemetry(
  outcome: execution.Outcome,
  model: String,
  emitter: telemetry.Emitter,
) -> Nil {
  case outcome {
    execution.Committed(
      target_id:,
      provider:,
      status:,
      usage:,
      duration_ms:,
      ..,
    ) ->
      telemetry.emit_scoped(
        emitter,
        telemetry.RequestStop(
          target_id:,
          provider:,
          model:,
          status:,
          duration_ms:,
          input_tokens: usage.prompt,
          output_tokens: usage.completion,
          cached_input_tokens: usage.cached,
        ),
      )
    execution.Exhausted(target_id:, provider:, reason:, ..) ->
      telemetry.emit_scoped(
        emitter,
        telemetry.RequestError(
          target_id: option.unwrap(target_id, ""),
          provider:,
          model:,
          error_type: reason,
        ),
      )
    execution.NoTargets(..) ->
      telemetry.emit_scoped(
        emitter,
        telemetry.RequestError(
          target_id: "",
          provider: "",
          model:,
          error_type: "no upstream targets available",
        ),
      )
    // A streaming commit is driven onto the connection by `execute_stream`;
    // its terminal telemetry is emitted by the chunked loop. Reaching here
    // would mean a commit was never driven — emit nothing.
    execution.CommittedStream(..) -> Nil
  }
}

/// Render an execution outcome as a mist response.
fn render_outcome(
  outcome: execution.Outcome,
) -> response.Response(mist.ResponseData) {
  case outcome {
    execution.Committed(status:, headers:, body:, ..) ->
      proxy.render_response(status, headers, body)
    execution.Exhausted(reason:, ..) ->
      response.new(502)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("upstream error: " <> reason)),
      )
    execution.NoTargets(..) ->
      response.new(503)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("no upstream targets available")),
      )
    // Unreachable in practice: a streaming commit is driven by
    // `execute_stream`, never rendered here. Defensive fallback.
    execution.CommittedStream(..) ->
      response.new(500)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(
          "streaming response was not driven onto the connection",
        )),
      )
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
  owner: tracing.Owner,
  emitter: telemetry.Emitter,
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
      let _ =
        tracing.call(owner, tracing.SelectStream(target_id, provider, status))
      proxy.stream_response(
        req,
        run,
        target_id,
        provider,
        model,
        status,
        start_time,
        owner,
        emitter,
      )
    }
    execution.Committed(..)
    | execution.Exhausted(..)
    | execution.NoTargets(..) -> {
      emit_outcome_telemetry(outcome, model, emitter)
      let rendered = render_outcome(outcome)
      let api = case path {
        "/v1/responses" -> pig_otel.Responses
        _ -> pig_otel.ChatCompletions
      }
      finish_buffered(owner, api, outcome, True)
      rendered
    }
  }
}

fn finish_buffered(
  owner: tracing.Owner,
  api: pig_otel.Api,
  outcome: execution.Outcome,
  requested_streaming: Bool,
) -> Nil {
  let #(terminal, metadata, status) = case outcome {
    execution.Committed(target_id:, provider:, status:, headers:, body:, ..) -> {
      let _ =
        tracing.call(
          owner,
          tracing.SelectedBufferedResponse(
            requested_streaming,
            status,
            headers,
            body,
            target_id,
            Some(provider),
          ),
        )
      #(
        tracing.http_outcome(status),
        trace_metadata.buffered(api, bit_array_to_string(body)),
        status,
      )
    }
    execution.Exhausted(..) -> #(
      pig_otel.Failed("transport_error"),
      trace_metadata.empty(),
      502,
    )
    execution.NoTargets(..) -> #(
      pig_otel.Failed("upstream_error"),
      trace_metadata.empty(),
      503,
    )
    execution.CommittedStream(..) -> #(
      pig_otel.Failed("callback_error"),
      trace_metadata.empty(),
      500,
    )
  }
  let _ =
    tracing.call(owner, tracing.LogicalTerminal(terminal, metadata, status))
  let _ = tracing.call(owner, tracing.Downstream(terminal))
  Nil
}

// ── Static responses ────────────────────────────────────────────

fn health_response() -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string("{\"status\":\"ok\"}")),
  )
}

fn metrics_response(
  state: ServerState,
) -> response.Response(mist.ResponseData) {
  case resolve_named(state.metrics) {
    Some(metrics_subject) -> {
      let snapshot = metrics.get_snapshot(metrics_subject)
      let catalog = case resolve_named(state.catalog) {
        Some(catalog_subject) -> model_catalog.snapshot(catalog_subject)
        None -> model_catalog.empty()
      }
      metrics_endpoint.response(snapshot, catalog)
    }
    None ->
      response.new(503)
      |> response.set_header("content-type", "text/plain")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string("metrics aggregator not started")),
      )
  }
}

fn not_found_response() -> response.Response(mist.ResponseData) {
  response.new(404)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string("{\"error\":{\"message\":\"not found\"}}")),
  )
}

fn bad_request_response(
  detail: String,
) -> response.Response(mist.ResponseData) {
  response.new(400)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(
      "{\"error\":{\"message\":\"" <> detail <> "\"}}",
    )),
  )
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
