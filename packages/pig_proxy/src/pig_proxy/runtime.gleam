//// Proxy runtime: bring up the actors a running proxy needs.
////
//// This is the deep module that owns the proxy's startup sequence and its
//// supervision tree. `main` (and programmatic embedders) call `start(config)`
//// and receive the assembled `ServerState`; everything else — which actors
//// to start, how they're supervised, how callers reach them after a restart
//// — lives here and nowhere else.
////
//// Supervision tree:
////
////   pig_proxy_sup (one_for_one, fail-to-boot)
////   ├── circuit        (named)  — per-target circuit breaker
////   ├── model_catalog  (named)  — models.dev refresher
////   ├── metrics        (named)  — typed-event aggregator
////   └── cred_sup (rest_for_one) — only when a Codex target is configured
////       ├── vault      (named)  — live credential store
////       └── refresh             — background Codex token rotation
////
//// Every supervised actor is started under a shared `process.Name` via
//// `actor.named`. On a crash the supervisor restarts just that actor (or,
//// for the cred pair, both under rest_for_one so refresh never targets a
//// dead vault), which re-registers the name — so the request path resolves
//// by name and transparently reaches the new process. Boot is
//// all-or-nothing: a child that fails to start fails the supervisor and the
//// proxy does not boot (fail-to-boot). The supervisor is linked to this
//// process so a tree death fails fast to an external restart.
////
//// The cred pair re-seeds from disk on each (re)start: the vault reloads the
//// persisted access token, and refresh reloads the persisted credential pair,
//// so a restart picks up the latest rotated credentials rather than the
//// boot-time snapshot.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
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

/// Bring up the proxy runtime for `cfg` and return the `ServerState` ready
/// to pass to `server.start`.
pub fn start(cfg: ProxyConfig) -> server.ServerState {
  // Shared names: created once, captured by the supervisor workers (which
  // register under them) and stored in ServerState (so the request path
  // resolves the CURRENT process after a restart).
  let circuit_name = process.new_name("circuit")
  let catalog_name = process.new_name("catalog")
  let metrics_name = process.new_name("metrics")
  let vault_name = process.new_name("vault")

  let plan = cred_plan(cfg)

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
    |> add_cred_sub(plan, vault_name)

  // Fail-to-boot: a child that can't start fails the supervisor, and thus
  // the proxy boot.
  let assert Ok(started) = static_supervisor.start(sup) as
    "pig_proxy: failed to start supervisor tree — a supervised actor would not start"
  // Fail-fast: if the tree later dies (restart intensity exceeded), take the
  // proxy down so an external supervisor restarts the whole process.
  let _ = process.link(started.pid)

  server.ServerState(
    config: cfg,
    routes: [],
    circuit: circuit_name,
    catalog: catalog_name,
    metrics: metrics_name,
    vault: vault_name_for(plan, vault_name),
  )
}

/// Conditionally add the credential sub-supervisor. No-op (no vault) when
/// no Codex target is configured or no credentials are available.
fn add_cred_sub(
  builder: static_supervisor.Builder,
  plan: Option(CredPlan),
  vault_name: process.Name(vault.VaultMsg),
) -> static_supervisor.Builder {
  case plan {
    Some(p) ->
      builder
      |> static_supervisor.add(cred_sub_child(p, vault_name))
    None -> builder
  }
}

/// The vault name exposed to the request path: present iff the cred
/// sub-tree was added.
fn vault_name_for(
  plan: Option(CredPlan),
  vault_name: process.Name(vault.VaultMsg),
) -> Option(process.Name(vault.VaultMsg)) {
  case plan {
    Some(_) -> Some(vault_name)
    None -> None
  }
}

// ── Credential sub-tree (rest_for_one) ─────────────────────────

/// A resolved plan for the credential sub-tree, decided at boot.
type CredPlan {
  /// Vault + refresh, both re-seeding/reloading from `path` on each restart.
  Full(target_id: String, path: String)
  /// Vault only, seeded from a static token (no refresh_token to rotate).
  Seeded(target_id: String, token: String)
}

/// Decide whether to start the credential sub-tree for `cfg`, and how.
/// `None` when no Codex target is configured or no credentials are
/// available — the proxy then serves with the static config.
fn cred_plan(cfg: ProxyConfig) -> Option(CredPlan) {
  case find_codex_target_id(cfg) {
    Some(target_id) -> {
      let path = codex_credentials.default_path()
      case codex_credentials.load(path) {
        Ok(_creds) -> Some(Full(target_id:, path:))
        Error(_reason) ->
          case cfg.codex_seed_token {
            Some(token) -> {
              logging.log(
                logging.Info,
                "no persisted Codex credentials — seeding vault for target \""
                  <> target_id
                  <> "\" from the configured seed token (no refresh)",
              )
              Some(Seeded(target_id:, token:))
            }
            None -> {
              logging.log(
                logging.Warning,
                "no Codex credentials at "
                  <> path
                  <> " and no seed token — live Codex token rotation disabled",
              )
              None
            }
          }
      }
    }
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

/// The credential pair as a sub-supervisor child of the top supervisor.
/// `rest_for_one`: a vault restart takes refresh down with it (refresh
/// re-resolves the vault name on restart), so rotation never targets a dead
/// vault. refresh crashing restarts only refresh.
fn cred_sub_child(
  plan: CredPlan,
  vault_name: process.Name(vault.VaultMsg),
) {
  supervision.supervisor(fn() { cred_sub_start(plan, vault_name) })
}

fn cred_sub_start(
  plan: CredPlan,
  vault_name: process.Name(vault.VaultMsg),
) -> Result(
  actor.Started(static_supervisor.Supervisor),
  actor.StartError,
) {
  let sub =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.add(vault_worker(plan, vault_name))
    |> add_refresh_worker(plan, vault_name)
  static_supervisor.start(sub)
}

/// The vault worker. On each (re)start it reloads the persisted access token
/// (Full) or uses the static seed (Seeded), so a restart picks up the latest
/// rotated credential.
fn vault_worker(
  plan: CredPlan,
  vault_name: process.Name(vault.VaultMsg),
) {
  supervision.worker(fn() { vault.start_named(vault_initial(plan), vault_name) })
}

/// The refresh worker (Full plan only). Reloads the persisted credential
/// pair on each (re)start so it rotates from the latest refresh token.
fn add_refresh_worker(
  builder: static_supervisor.Builder,
  plan: CredPlan,
  vault_name: process.Name(vault.VaultMsg),
) -> static_supervisor.Builder {
  case plan {
    Full(target_id:, path:) ->
      builder
      |> static_supervisor.add(supervision.worker(fn() {
        case codex_credentials.load(path) {
          Ok(creds) ->
            codex_refresh.start_started(
              vault_name,
              target_id,
              path,
              creds,
              codex_refresh.default_check_interval_ms,
              codex_refresh.default_refresh_buffer_ms,
            )
          Error(reason) -> {
            logging.log(
              logging.Error,
              "pig_proxy: could not reload Codex credentials from "
                <> path
                <> ": "
                <> reason,
            )
            Error(actor.InitFailed("could not reload Codex credentials"))
          }
        }
      }))
    Seeded(..) -> builder
  }
}

/// Build the vault's initial credentials from the plan (reloaded fresh each
/// time this runs, i.e. on every vault start/restart).
fn vault_initial(plan: CredPlan) -> Dict(String, vault.Credential) {
  case plan {
    Full(target_id:, path:) ->
      case codex_credentials.load(path) {
        Ok(creds) ->
          vault.initial_credentials([
            #(target_id, vault.CodexToken(creds.access_token)),
          ])
        Error(_reason) ->
          // No persisted creds on a Full restart: start an empty vault. The
          // refresh worker (also restarting under rest_for_one) populates it
          // once it rotates.
          vault.initial_credentials([])
      }
    Seeded(target_id:, token:) ->
      vault.initial_credentials([#(target_id, vault.CodexToken(token))])
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
