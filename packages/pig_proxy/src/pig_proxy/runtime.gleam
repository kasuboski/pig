//// Proxy runtime: bring up the actors a running proxy needs.
////
//// This is the deep module that owns the proxy's startup sequence, its
//// graceful-degradation policy, and its supervision policy. `main` (and
//// programmatic embedders) call `start(config)` and receive the assembled
//// `ServerState`; everything else — which actors to start, what happens
//// when one fails, which crashes must fail-fast — lives here and nowhere
//// else.
////
//// Degradation policy (start-time failures):
////   - metrics / model_catalog / circuit: optional. A start failure logs a
////     warning and the proxy serves without that feature (/metrics disabled,
////     cost metrics zero, no circuit protection).
////   - credential vault: optional. Without it the proxy serves with the
////     static config baked into `TargetAuth`.
////   - Codex refresh: optional, but its crash is fail-fast (see below).
////
//// Supervision policy (runtime crashes):
////   - The Codex refresh actor is LINKED to the calling process. Silent
////     loss of token rotation would leave the proxy serving soon-to-expire
////     tokens, so a crash is surfaced and triggers an external restart
////     (systemd / k8s / the `gleam run` process) rather than degrading.
////   - The observability actors are intentionally unlinked: losing metrics
////     mid-run is preferable to killing in-flight requests.

import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import logging
import pig_proxy/circuit_actor
import pig_proxy/codex_credentials
import pig_proxy/codex_refresh
import pig_proxy/config.{type ProxyConfig}
import pig_proxy/metrics
import pig_proxy/model_catalog
import pig_proxy/server
import pig_proxy/vault

/// Bring up the proxy runtime for `cfg`: start the metrics aggregator, the
/// models.dev catalog refresher, the per-target circuit breaker, and (when
/// a Codex target is configured) the credential vault and token-refresh
/// actor. Returns the `ServerState` ready to pass to `server.start`.
pub fn start(cfg: ProxyConfig) -> server.ServerState {
  let metrics_subject = start_metrics()
  let catalog_subject = start_catalog(cfg)
  let circuit_subject = start_circuit(cfg)
  let #(vault_subject, refresh_subject) = start_credentials(cfg)
  let _ = link_refresh_actor(refresh_subject)

  server.ServerState(
    config: cfg,
    routes: [],
    metrics: metrics_subject,
    catalog: catalog_subject,
    vault: vault_subject,
    circuit: circuit_subject,
  )
}

// ── Optional actors (graceful degradation) ──────────────────────

fn start_metrics() -> Option(process.Subject(metrics.MetricsMsg)) {
  case metrics.start() {
    Ok(#(subject, _handler_id)) -> Some(subject)
    Error(_) -> {
      logging.log(
        logging.Warning,
        "failed to start metrics aggregator — /metrics endpoint disabled",
      )
      None
    }
  }
}

fn start_catalog(cfg: ProxyConfig) -> Option(
  process.Subject(model_catalog.CatalogMsg),
) {
  case model_catalog.start(cfg.models_dev_url, cfg.models_refresh_ms) {
    Ok(subject) -> Some(subject)
    Error(_) -> {
      logging.log(
        logging.Warning,
        "failed to start model catalog — cost metrics will be zero",
      )
      None
    }
  }
}

fn start_circuit(cfg: ProxyConfig) -> Option(
  process.Subject(circuit_actor.CircuitMsg),
) {
  case circuit_actor.start(cfg.circuit_threshold, cfg.circuit_cooldown_ms) {
    Ok(subject) -> Some(subject)
    Error(_) -> {
      logging.log(
        logging.Warning,
        "failed to start circuit breaker actor — circuit protection disabled",
      )
      None
    }
  }
}

// ── Codex credentials + vault + refresh ─────────────────────────

/// Load persisted Codex credentials (if present) and wire them into the
/// credential vault + background refresh actor so access tokens stay
/// valid without depending on the Codex CLI. Returns the vault subject
/// (or `None`) and the refresh actor subject (or `None`). See
/// `pig_proxy/codex_login` for obtaining the initial credential pair.
fn start_credentials(
  cfg: ProxyConfig,
) -> #(
  Option(process.Subject(vault.VaultMsg)),
  Option(process.Subject(codex_refresh.RefreshMsg)),
) {
  case find_codex_target_id(cfg) {
    Some(target_id) -> start_credentials_for_target(cfg, target_id)
    None -> {
      logging.log(
        logging.Warning,
        "no target is configured for ChatGPT/Codex OAuth — live Codex"
          <> " token rotation disabled",
      )
      #(None, None)
    }
  }
}

/// Load persisted Codex credentials for `target_id` and wire them into the
/// vault + refresh actor. When persisted credentials are unavailable, fall
/// back to the configured seed token (`OPENAI_COMPAT_CODEX_TOKEN`) to seed
/// the vault without refresh.
fn start_credentials_for_target(
  cfg: ProxyConfig,
  target_id: String,
) -> #(
  Option(process.Subject(vault.VaultMsg)),
  Option(process.Subject(codex_refresh.RefreshMsg)),
) {
  let path = codex_credentials.default_path()
  case codex_credentials.load(path) {
    Ok(creds) -> start_vault_and_refresh(target_id, creds, path)
    Error(reason) ->
      case cfg.codex_seed_token {
        Some(token) -> start_vault_seeded(target_id, token)
        None -> {
          logging.log(
            logging.Warning,
            "could not load Codex credentials from "
              <> path
              <> ": "
              <> reason
              <> " — live Codex token rotation disabled",
          )
          #(None, None)
        }
      }
  }
}

/// Seed the vault with a static Codex token (no refresh actor, since a seed
/// token carries no refresh token). Degrades to `(None, None)` if the
/// vault cannot start.
fn start_vault_seeded(
  target_id: String,
  token: String,
) -> #(
  Option(process.Subject(vault.VaultMsg)),
  Option(process.Subject(codex_refresh.RefreshMsg)),
) {
  let initial =
    vault.initial_credentials([#(target_id, vault.CodexToken(token))])
  case vault.start(initial) {
    Ok(v) -> {
      logging.log(
        logging.Info,
        "seeded credential vault for Codex target \""
          <> target_id
          <> "\" from the configured seed token (no refresh)",
      )
      #(Some(v), None)
    }
    Error(_) -> {
      logging.log(
        logging.Warning,
        "failed to start credential vault — live credential rotation"
          <> " disabled",
      )
      #(None, None)
    }
  }
}

/// Start the credential vault seeded with the Codex access token, then
/// start the background refresh actor against it. Degrades gracefully:
/// `(Some(vault), None)` if only the refresh actor fails, or `(None, None)`
/// if the vault itself cannot start — so the proxy still serves with the
/// static config when live rotation is off.
fn start_vault_and_refresh(
  target_id: String,
  creds: codex_credentials.CodexCredentials,
  path: String,
) -> #(
  Option(process.Subject(vault.VaultMsg)),
  Option(process.Subject(codex_refresh.RefreshMsg)),
) {
  let initial =
    vault.initial_credentials([#(target_id, vault.CodexToken(creds.access_token))])
  case vault.start(initial) {
    Ok(v) ->
      case
        codex_refresh.start(
          v,
          target_id,
          path,
          creds,
          codex_refresh.default_check_interval_ms,
          codex_refresh.default_refresh_buffer_ms,
        )
      {
        Ok(refresh) -> #(Some(v), Some(refresh))
        Error(_) -> {
          logging.log(
            logging.Warning,
            "failed to start Codex token refresh actor — tokens will not"
              <> " be refreshed automatically",
          )
          #(Some(v), None)
        }
      }
    Error(_) -> {
      logging.log(
        logging.Warning,
        "failed to start credential vault — live credential rotation"
          <> " disabled",
      )
      #(None, None)
    }
  }
}

// ── Supervision ─────────────────────────────────────────────────

/// Link the Codex refresh actor to the calling process so a crash is
/// surfaced and triggers an external restart, rather than silently
/// stopping token rotation. No-op when no refresh actor was started.
fn link_refresh_actor(
  refresh: Option(process.Subject(codex_refresh.RefreshMsg)),
) -> Nil {
  case refresh {
    Some(subject) ->
      case process.subject_owner(subject) {
        Ok(pid) -> {
          let _ = process.link(pid)
          Nil
        }
        Error(_) -> Nil
      }
    None -> Nil
  }
}

// ── Helpers ─────────────────────────────────────────────────────

/// Find the target id that should hold the Codex credential: the first
/// target whose `TargetAuth` is `Codex`. Returns `None` when no such
/// target exists, so the caller can disable Codex bootstrap rather than
/// injecting an OAuth token into a non-Codex target.
fn find_codex_target_id(cfg: ProxyConfig) -> Option(String) {
  case list.find(cfg.targets, config.is_codex_target) {
    Ok(t) -> Some(t.id)
    Error(_) -> None
  }
}
