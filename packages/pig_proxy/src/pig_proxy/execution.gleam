//// Proxy request execution.
////
//// Takes a Proxy Request and a Fallback Chain and walks it under the
//// circuit-breaker, per-target retry-budget, and commit-point semantics.
//// Retry, fallback, circuit admission, credential resolution, and
//// backoff live here, above the transport seam; HTTP mechanics live in
//// the adapter. The result is a typed `Outcome` — the test surface — so
//// callers and tests assert on decisions, not rendered bytes.
////
//// Both shapes share one walk: `orchestrate` (synchronous) and
//// `orchestrate_stream` (streaming) differ only in the per-attempt
//// primitive they hand to the walk. The commit point is where they
//// diverge — a sync attempt commits on any non-retryable status; a
//// stream attempt commits on the first byte (`StreamCommitted`).
////
//// Telemetry is owned by the caller: the walk returns everything a
//// single attributed terminal event needs, and the caller emits exactly
//// one (for sync, from the `Outcome`; for streaming, from the chunked
//// loop when the relay finishes). This keeps the walk free of the
//// telemetry registry and trivially testable.

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

/// Default upstream timeout for requests (120 s).
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
  /// Covers both sync commits and streaming attempts that returned a
  /// non-retryable non-2xx head (forwarded verbatim).
  Committed(
    target_id: String,
    provider: String,
    status: Int,
    headers: List(#(String, String)),
    body: BitArray,
    usage: proxy.Usage,
    duration_ms: Int,
  )
  /// A target committed to a live streaming response (2xx head + first
  /// byte). The relay `run` subject forwards the remaining bytes once the
  /// caller starts it; the caller owns the chunked loop and the terminal
  /// telemetry for this target.
  CommittedStream(
    target_id: String,
    provider: String,
    status: Int,
    run: process.Subject(transport.RelayControl),
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
pub fn with_vault(
  executor: Executor,
  vault: process.Subject(vault.VaultMsg),
) -> Executor {
  Executor(..executor, vault: Some(vault))
}

/// Set the Per-Target Retry Budget (additional attempts after the first).
pub fn with_retries_per_target(executor: Executor, retries: Int) -> Executor {
  Executor(..executor, retries_per_target: retries)
}

/// Walk the fallback chain for a synchronous request and return the
/// outcome.
pub fn orchestrate(
  executor: Executor,
  request: ProxyRequest,
  chain: FallbackChain,
) -> Outcome {
  let start = telemetry.system_time()
  walk(executor, request, chain.targets, start, sync_attempt)
}

/// Walk the fallback chain for a streaming request and return the
/// outcome. Retry and fallback apply only before the first byte; once a
/// target returns `CommittedStream`, the walk stops.
pub fn orchestrate_stream(
  executor: Executor,
  request: ProxyRequest,
  chain: FallbackChain,
) -> Outcome {
  let start = telemetry.system_time()
  walk(executor, request, chain.targets, start, stream_attempt)
}

fn walk(
  executor: Executor,
  request: ProxyRequest,
  targets: List(UpstreamTarget),
  start: Int,
  attempt_fn: AttemptFn,
) -> Outcome {
  walk_with(executor, request, targets, start, attempt_fn, None)
}

/// Walk the chain carrying the last `Exhausted` outcome seen. If the chain
/// ends with every remaining target circuit-skipped, the prior exhaustion
/// is reported (a 502 attributed to the last attempted target) rather than
/// `NoTargets` — exhaustion must not be masked by skipped targets.
fn walk_with(
  executor: Executor,
  request: ProxyRequest,
  targets: List(UpstreamTarget),
  start: Int,
  attempt_fn: AttemptFn,
  last_exhausted: Option(Outcome),
) -> Outcome {
  case targets {
    [] ->
      case last_exhausted {
        Some(exhausted) -> exhausted
        None -> NoTargets(telemetry.system_time() - start)
      }
    [target, ..rest] ->
      case admit(executor, target.id) {
        False -> {
          logging.log(
            logging.Debug,
            "execution: skipping target \"" <> target.id <> "\" — circuit open",
          )
          walk_with(executor, request, rest, start, attempt_fn, last_exhausted)
        }
        True -> {
          let outcome = attempt_target(executor, request, target, start, attempt_fn)
          case outcome {
            Committed(..) -> outcome
            CommittedStream(..) -> outcome
            exhausted ->
              walk_with(executor, request, rest, start, attempt_fn, Some(exhausted))
          }
        }
      }
  }
}

/// Attempt one target up to its retry budget; on a commit return a
/// committed outcome, otherwise record one circuit failure and return
/// `Exhausted` for this target.
fn attempt_target(
  executor: Executor,
  request: ProxyRequest,
  target: UpstreamTarget,
  start: Int,
  attempt_fn: AttemptFn,
) -> Outcome {
  let auth = resolve_auth(target, executor.vault)
  case attempt_loop(executor, request, target, auth, 0, attempt_fn) {
    CommittedForward(status:, headers:, body:) -> {
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
    Streaming(status:, run:) -> {
      record_success(executor, target.id)
      CommittedStream(
        target_id: target.id,
        provider: config.provider_string(target),
        status:,
        run:,
      )
    }
    BudgetExhausted(reason) -> {
      record_failure(executor, target.id)
      Exhausted(
        target_id: Some(target.id),
        provider: config.provider_string(target),
        reason:,
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
  attempt_fn: AttemptFn,
) -> CommitResult {
  case attempt_fn(executor, request, target, auth) {
    Forward(status:, headers:, body:) -> CommittedForward(status:, headers:, body:)
    Stream(status:, run:) -> Streaming(status:, run:)
    Transient(reason:, retry_after:) ->
      case attempt >= executor.retries_per_target {
        True -> BudgetExhausted(reason)
        False -> {
          let delay =
            retry.retry_delay(attempt, retry_base_ms, retry_max_ms, retry_after)
          logging.log(
            logging.Debug,
            "execution: retrying target \""
              <> target.id
              <> "\" after "
              <> int.to_string(delay)
              <> "ms",
          )
          executor.sleep(delay)
          attempt_loop(executor, request, target, auth, attempt + 1, attempt_fn)
        }
      }
  }
}

// ── Per-shape attempt primitives ────────────────────────────────

/// One synchronous upstream attempt, classified into the walk's terms.
fn sync_attempt(
  executor: Executor,
  request: ProxyRequest,
  target: UpstreamTarget,
  auth: proxy.ResolvedAuth,
) -> AttemptResult {
  let req = build_transport_request(executor, request, target, auth, False)
  case transport.sync(executor.transport, req) {
    transport.TransportError(reason) -> Transient(reason:, retry_after: None)
    transport.Response(status:, headers:, body:) ->
      case retry.is_retryable_status(status) {
        True ->
          Transient(
            reason: "upstream_" <> int.to_string(status),
            retry_after: retry_after_of(headers),
          )
        False -> Forward(status:, headers:, body:)
      }
  }
}

/// One streaming upstream attempt, classified into the walk's terms. The
/// commit point is `StreamCommitted`; a non-retryable non-2xx head is
/// forwarded verbatim (like a sync 4xx); a retryable head or a
/// connect-level failure consumes budget.
fn stream_attempt(
  executor: Executor,
  request: ProxyRequest,
  target: UpstreamTarget,
  auth: proxy.ResolvedAuth,
) -> AttemptResult {
  let req = build_transport_request(executor, request, target, auth, True)
  case transport.stream(executor.transport, req) {
    transport.StreamCommitted(status:, run:, ..) -> Stream(status:, run:)
    transport.StreamRejected(status:, headers:, body:) ->
      case retry.is_retryable_status(status) {
        True ->
          Transient(
            reason: "upstream_" <> int.to_string(status),
            retry_after: retry_after_of(headers),
          )
        False -> Forward(status:, headers:, body:)
      }
    transport.StreamFailure(reason) -> Transient(reason:, retry_after: None)
  }
}

fn build_transport_request(
  executor: Executor,
  request: ProxyRequest,
  target: UpstreamTarget,
  auth: proxy.ResolvedAuth,
  streaming: Bool,
) -> transport.TransportRequest {
  transport.TransportRequest(
    method: request.method,
    url: proxy.resolve_upstream_url(target, request.path),
    headers:
      proxy.build_upstream_headers(request.headers, target.base_url, auth, streaming),
    body: request.body,
    timeout_ms: executor.upstream_timeout_ms,
  )
}

fn retry_after_of(headers: List(#(String, String))) -> Option(String) {
  case list.find(headers, fn(h) { string.lowercase(h.0) == "retry-after" }) {
    Ok(#(_, value)) -> Some(value)
    Error(_) -> None
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

// ── Internal types ──────────────────────────────────────────────

/// A per-attempt primitive, shared by both shapes.
type AttemptFn =
  fn(Executor, ProxyRequest, UpstreamTarget, proxy.ResolvedAuth) -> AttemptResult

/// One attempt classified into the walk's terms: commit (forward or
/// stream) or transient (consume budget).
type AttemptResult {
  Forward(status: Int, headers: List(#(String, String)), body: BitArray)
  Stream(status: Int, run: process.Subject(transport.RelayControl))
  Transient(reason: String, retry_after: Option(String))
}

/// What `attempt_loop` resolves to.
type CommitResult {
  CommittedForward(status: Int, headers: List(#(String, String)), body: BitArray)
  Streaming(status: Int, run: process.Subject(transport.RelayControl))
  BudgetExhausted(reason: String)
}
