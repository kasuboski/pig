//// Proxy request execution.
////
//// Takes a Proxy Request and a Fallback Chain and walks it under the
//// circuit-breaker, per-target retry-budget, and commit-point semantics.
//// Retry, fallback, circuit admission, credential resolution, and
//// backoff live here, above the transport seam; HTTP mechanics live in
//// the adapter. The result is a typed `Outcome` — the test surface — so
//// callers and tests assert on decisions, not rendered bytes.
////
//// Telemetry is owned by the caller: `orchestrate` returns everything a
//// single attributed `RequestStop`/`RequestError` needs, and the caller
//// emits exactly one terminal event from it. This keeps `orchestrate`
//// free of the telemetry registry and trivially testable.
////
//// Only synchronous execution is implemented here. A streaming variant
//// (the commit point becomes the first byte) is added alongside the
//// streaming transport adapter.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import logging
import pig_proxy/circuit_actor
import pig_proxy/config.{type UpstreamTarget}
import pig_proxy/proxy
import pig_proxy/retry
import pig_proxy/telemetry
import pig_proxy/transport
import pig_proxy/vault

/// Base delay for retry backoff (1 second).
const retry_base_ms = 1000

/// Maximum retry backoff cap (30 seconds).
const retry_max_ms = 30_000

/// Default upstream timeout for non-streaming requests (120 s).
const default_upstream_timeout_ms = 120_000

/// Default Per-Target Retry Budget: one additional attempt per target.
pub const default_retries_per_target = 1

/// A proxy request awaiting execution.
pub type ProxyRequest {
  ProxyRequest(
    method: String,
    path: String,
    headers: List(#(String, String)),
    body: String,
    model: String,
  )
}

/// The ordered upstream targets to attempt; the head is tried first.
pub type FallbackChain {
  FallbackChain(targets: List(UpstreamTarget))
}

/// The result of walking a fallback chain. The caller renders this and
/// emits exactly one terminal telemetry event from it.
pub type Outcome {
  /// A target produced a response to forward (any non-retryable status,
  /// including client 4xx — those are valid responses, not failures).
  Committed(
    target_id: String,
    provider: String,
    status: Int,
    headers: List(#(String, String)),
    body: BitArray,
    usage: proxy.Usage,
    duration_ms: Int,
  )
  /// Every target was attempted and exhausted its retry budget.
  Exhausted(
    target_id: Option(String),
    provider: String,
    reason: String,
    duration_ms: Int,
  )
  /// The chain was empty or every target was skipped by an open circuit
  /// before any attempt.
  NoTargets(duration_ms: Int)
}

/// The collaborators execution needs, injected as values. The module
/// holds no state of its own; circuit and vault state live in their actors.
pub type Executor {
  Executor(
    transport: transport.Transport,
    circuit: Option(process.Subject(circuit_actor.CircuitMsg)),
    vault: Option(process.Subject(vault.VaultMsg)),
    /// Additional attempts per target after the first. Resets per target.
    retries_per_target: Int,
    upstream_timeout_ms: Int,
    /// Backoff sleep. Inject a no-op in tests for determinism.
    sleep: fn(Int) -> Nil,
  )
}

/// Build an executor with sensible defaults and the given collaborators.
pub fn executor(
  transport: transport.Transport,
  circuit: Option(process.Subject(circuit_actor.CircuitMsg)),
) -> Executor {
  Executor(
    transport:,
    circuit:,
    vault: None,
    retries_per_target: default_retries_per_target,
    upstream_timeout_ms: default_upstream_timeout_ms,
    sleep: fn(ms) { process.sleep(ms) },
  )
}

/// Set the credential vault used to resolve live Codex tokens.
pub fn with_vault(executor: Executor, vault: process.Subject(vault.VaultMsg)) -> Executor {
  Executor(..executor, vault: Some(vault))
}

/// Set the Per-Target Retry Budget (additional attempts after the first).
pub fn with_retries_per_target(executor: Executor, retries: Int) -> Executor {
  Executor(..executor, retries_per_target: retries)
}

/// Walk the fallback chain and return the outcome.
pub fn orchestrate(
  executor: Executor,
  request: ProxyRequest,
  chain: FallbackChain,
) -> Outcome {
  let start = telemetry.system_time()
  walk(executor, request, chain.targets, start)
}

fn walk(
  executor: Executor,
  request: ProxyRequest,
  targets: List(UpstreamTarget),
  start: Int,
) -> Outcome {
  case targets {
    [] -> NoTargets(telemetry.system_time() - start)
    [target, ..rest] -> {
      case admit(executor, target.id) {
        False -> {
          logging.log(
            logging.Debug,
            "execution: skipping target \"" <> target.id <> "\" — circuit open",
          )
          walk(executor, request, rest, start)
        }
        True ->
          case attempt_target(executor, request, target, start) {
            Committed(..) as committed -> committed
            exhausted ->
              case rest {
                [] -> exhausted
                _ -> walk(executor, request, rest, start)
              }
          }
      }
    }
  }
}

/// Attempt one target up to its retry budget; on a commit return
/// `Committed`, otherwise record one circuit failure and return
/// `Exhausted` for this target.
fn attempt_target(
  executor: Executor,
  request: ProxyRequest,
  target: UpstreamTarget,
  start: Int,
) -> Outcome {
  let auth = resolve_auth(target, executor.vault)
  case attempt_loop(executor, request, target, auth, 0) {
    CommittedAttempt(status:, headers:, body:) -> {
      record_success(executor, target.id)
      Committed(
        target_id: target.id,
        provider: config.provider_string(target),
        status:,
        headers:,
        body:,
        usage: proxy.parse_usage(body_to_string(body)),
        duration_ms: telemetry.system_time() - start,
      )
    }
    ExhaustedAttempt(resp) -> {
      record_failure(executor, target.id)
      Exhausted(
        target_id: Some(target.id),
        provider: config.provider_string(target),
        reason: exhaustion_reason(resp),
        duration_ms: telemetry.system_time() - start,
      )
    }
  }
}

/// Loop the per-target retry budget. `attempt` counts retries already
/// performed (0 on the first attempt); total attempts are
/// `1 + retries_per_target`.
fn attempt_loop(
  executor: Executor,
  request: ProxyRequest,
  target: UpstreamTarget,
  auth: proxy.ResolvedAuth,
  attempt: Int,
) -> AttemptResult {
  let req =
    transport.TransportRequest(
      method: request.method,
      url: proxy.resolve_upstream_url(target, request.path),
      headers:
        proxy.build_upstream_headers(request.headers, target.base_url, auth, False),
      body: request.body,
      timeout_ms: executor.upstream_timeout_ms,
    )
  let resp = transport.sync(executor.transport, req)
  case classify(resp) {
    Commit -> {
      let assert transport.Response(status:, headers:, body:) = resp
      CommittedAttempt(status:, headers:, body:)
    }
    Retry ->
      case attempt >= executor.retries_per_target {
        True -> ExhaustedAttempt(resp)
        False -> {
          let delay =
            retry.retry_delay(attempt, retry_base_ms, retry_max_ms, retry_after_of(resp))
          logging.log(
            logging.Debug,
            "execution: retrying target \""
              <> target.id
              <> "\" after "
              <> int.to_string(delay)
              <> "ms",
          )
          executor.sleep(delay)
          attempt_loop(executor, request, target, auth, attempt + 1)
        }
      }
  }
}

/// How to treat one transport outcome. A retryable status or a transport
/// error consumes budget; anything else (2xx or client 4xx) commits.
fn classify(resp: transport.TransportResponse) -> Verdict {
  case resp {
    transport.TransportError(_) -> Retry
    transport.Response(status:, ..) ->
      case retry.is_retryable_status(status) {
        True -> Retry
        False -> Commit
      }
  }
}

fn retry_after_of(resp: transport.TransportResponse) -> Option(String) {
  case resp {
    transport.Response(headers:, ..) ->
      list.find(headers, fn(h) { string.lowercase(h.0) == "retry-after" })
      |> result.map(fn(entry) {
        let #(_, value) = entry
        value
      })
      |> option.from_result
    transport.TransportError(_) -> None
  }
}

fn exhaustion_reason(resp: transport.TransportResponse) -> String {
  case resp {
    transport.TransportError(reason:) -> reason
    transport.Response(status:, ..) -> "upstream_" <> int.to_string(status)
  }
}

fn body_to_string(body: BitArray) -> String {
  result.unwrap(bit_array.to_string(body), "")
}

// ── Circuit + credential resolution ─────────────────────────────

fn admit(executor: Executor, target_id: String) -> Bool {
  case executor.circuit {
    Some(c) -> circuit_actor.admit(c, target_id, 2000)
    None -> True
  }
}

fn record_failure(executor: Executor, target_id: String) -> Nil {
  case executor.circuit {
    Some(c) -> circuit_actor.record_failure(c, target_id)
    None -> Nil
  }
}

fn record_success(executor: Executor, target_id: String) -> Nil {
  case executor.circuit {
    Some(c) -> circuit_actor.record_success(c, target_id)
    None -> Nil
  }
}

/// Resolve the concrete authentication for a target: the live credential
/// from the vault when present, otherwise the target's static `TargetAuth`.
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
        "execution: Codex target \""
          <> target.id
          <> "\" has no live token in the vault — requests will be"
          <> " unauthenticated",
      )
      proxy.Codex("")
    }
  }
}

// ── Internal attempt results ────────────────────────────────────

type Verdict {
  Commit
  Retry
}

type AttemptResult {
  CommittedAttempt(status: Int, headers: List(#(String, String)), body: BitArray)
  ExhaustedAttempt(resp: transport.TransportResponse)
}
