//// Proxy runtime: bring up the actors a running proxy needs.
////
//// This is the deep module that owns the proxy's startup sequence and its
//// supervision tree. `main` (and programmatic embedders) call `start(config)`
//// and receive the assembled `ServerState`; everything else — which actors
//// to start, how they're supervised, how callers reach them after a restart
//// — lives here and nowhere else.
////
//// Supervision:
////   The independent actors (circuit breaker, model catalog, metrics) are
////   owned by a `static_supervisor` (one_for_one), each started under a
////   shared `process.Name` via `actor.named`. On a crash the supervisor
////   restarts just that actor, which re-registers the name — so the request
////   path (which resolves by name) transparently reaches the new process.
////   Boot is all-or-nothing: if any supervised actor fails to start, the
////   supervisor fails and the proxy does not boot (fail-to-boot).
////
////   The credential vault + Codex refresh pair are started manually for now:
////   they are coupled (refresh depends on the vault) and re-seeding the
////   vault from persisted credentials on restart wants a rest_for_one
////   sub-tree, which is a deliberate follow-up. Both are name-addressed so
////   the move into the tree is mechanical later; the refresh actor is linked
////   to this process so silent loss of token rotation fails fast.

import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result
import logging
import pig_proxy/circuit_actor
import pig_proxy/codex_credentials
import pig_proxy/codex_refresh
import pig_proxy/config.{type ProxyConfig}
import pig_proxy/metrics
import pig_proxy/model_catalog
import pig_proxy/server
import pig_proxy/vault

/// Bring up the proxy runtime for `cfg`: start and supervise the circuit
/// breaker, model catalog, and metrics aggregator; start the credential
/// vault + Codex refresh (when a Codex target is configured). Returns the
/// `ServerState` ready to pass to `server.start`.
pub fn start(cfg: ProxyConfig) -> server.ServerState {
  // Shared names: created once, captured by the supervisor workers (which
  // register under them) and stored in ServerState (so the request path
  // resolves the CURRENT process after a restart).
  let circuit_name = process.new_name("circuit")
  let catalog_name = process.new_name("catalog")
  let metrics_name = process.new_name("metrics")

  let sup =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(supervision.worker(fn() {
      circuit_actor.start_named(
        cfg.circuit_threshold,
        cfg.circuit_cooldown_ms,
        circuit_name,
      )
    }))
    |> static_supervisor.add(supervision.worker(fn() {
      model_catalog.start_named(
        cfg.models_dev_url,
        cfg.models_refresh_ms,
        catalog_name,
      )
    }))
    |> static_supervisor.add(supervision.worker(fn() {
      // metrics.start_named attaches a typed telemetry handler too; the
      // handler id is discarded (a restarted metrics actor leaves the prior
      // handler as a harmless no-op that forwards to a dead subject).
      metrics.start_named(metrics_name)
      |> result.map(fn(pair) {
        let #(started, _handler_id) = pair
        started
      })
    }))

  // Fail-to-boot: a child that can't start fails the supervisor, and thus
  // the proxy boot.
  let assert Ok(started) = static_supervisor.start(sup) as
    "pig_proxy: failed to start supervisor tree — a supervised actor would not start"
  // Fail-fast: if the tree later dies (restart intensity exceeded), take the
  // proxy down so an external supervisor restarts the whole process.
  let _ = process.link(started.pid)

  // Credential vault + refresh (manual; coupled pair — see module doc).
  let vault_subject = start_credentials(cfg)

  server.ServerState(
    config: cfg,
    routes: [],
    circuit: circuit_name,
    catalog: catalog_name,
    metrics: metrics_name,
    vault: vault_subject,
  )
}

// ── Credential vault + refresh (manual, Codex-optional) ────────

/// Load persisted Codex credentials (if present) and wire them into the
/// credential vault + background refresh actor, returning the vault subject
/// (or `None`). See `pig_proxy/codex_login` for obtaining the initial pair.
fn start_credentials(
  cfg: ProxyConfig,
) -> Option(process.Subject(vault.VaultMsg)) {
  case find_codex_target_id(cfg) {
    Some(target_id) -> start_credentials_for_target(cfg, target_id)
    None -> {
      logging.log(
        logging.Warning,
        "no target is configured for ChatGPT/Codex OAuth — live Codex"
          <> " token rotation disabled",
      )
      None
    }
  }
}

fn start_credentials_for_target(
  cfg: ProxyConfig,
  target_id: String,
) -> Option(process.Subject(vault.VaultMsg)) {
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
          None
        }
      }
  }
}

/// Seed the vault with a static Codex token (no refresh actor, since a seed
/// token carries no refresh token). The vault is started under a name so the
/// future supervised path reuses the same wiring.
fn start_vault_seeded(target_id: String, token: String) -> Option(
  process.Subject(vault.VaultMsg),
) {
  let vault_name = process.new_name("vault")
  let initial =
    vault.initial_credentials([#(target_id, vault.CodexToken(token))])
  case vault.start_named(initial, vault_name) {
    Ok(started) -> {
      logging.log(
        logging.Info,
        "seeded credential vault for Codex target \""
          <> target_id
          <> "\" from the configured seed token (no refresh)",
      )
      Some(started.data)
    }
    Error(_) -> {
      logging.log(
        logging.Warning,
        "failed to start credential vault — live credential rotation"
          <> " disabled",
      )
      None
    }
  }
}

/// Start the credential vault under a name, seeded with the Codex access
/// token, then start the background refresh actor against it (addressed by
/// the same name). The refresh actor is linked to this process so silent
/// loss of token rotation fails fast. Degrades to `None` if the vault cannot
/// start.
fn start_vault_and_refresh(
  target_id: String,
  creds: codex_credentials.CodexCredentials,
  path: String,
) -> Option(process.Subject(vault.VaultMsg)) {
  let vault_name = process.new_name("vault")
  let initial =
    vault.initial_credentials([#(target_id, vault.CodexToken(creds.access_token))])
  case vault.start_named(initial, vault_name) {
    Ok(started) -> {
      case
        codex_refresh.start(
          vault_name,
          target_id,
          path,
          creds,
          codex_refresh.default_check_interval_ms,
          codex_refresh.default_refresh_buffer_ms,
        )
      {
        Ok(refresh) -> {
          // Link the refresh actor so a crash surfaces and triggers an
          // external restart instead of silently stopping rotation.
          case process.subject_owner(refresh) {
            Ok(pid) -> {
              let _ = process.link(pid)
              Nil
            }
            Error(_) -> Nil
          }
        }
        Error(_) ->
          logging.log(
            logging.Warning,
            "failed to start Codex token refresh actor — tokens will not"
              <> " be refreshed automatically",
          )
      }
      Some(started.data)
    }
    Error(_) -> {
      logging.log(
        logging.Warning,
        "failed to start credential vault — live credential rotation"
          <> " disabled",
      )
      None
    }
  }
}

// ── Helpers ─────────────────────────────────────────────────────

/// Find the target id that should hold the Codex credential: the first
/// target whose `TargetAuth` is `Codex`.
fn find_codex_target_id(cfg: ProxyConfig) -> Option(String) {
  case list.find(cfg.targets, config.is_codex_target) {
    Ok(t) -> Some(t.id)
    Error(_) -> None
  }
}
