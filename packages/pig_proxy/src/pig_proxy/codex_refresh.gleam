//// Background Codex OAuth token refresh actor.
////
//// Periodically checks whether the current Codex access token is close
//// to expiring and, if so, exchanges the refresh token for a new pair via
//// `pig_proxy/codex_login.refresh`. On success the new access token is
//// pushed into the credential vault (so in-flight and future requests
//// pick it up immediately via `vault.rotate_token`) and persisted to disk
//// via `pig_proxy/codex_credentials.save`, so pig_proxy never depends on
//// the Codex CLI to keep credentials valid.

import gleam/erlang/process
import gleam/option.{type Option}
import gleam/otp/actor
import logging
import pig_proxy/codex_credentials.{type CodexCredentials}
import pig_proxy/codex_login
import pig_proxy/telemetry
import pig_proxy/vault

/// How often the actor wakes up to check expiry.
pub const default_check_interval_ms = 60_000

/// Refresh proactively this far ahead of actual expiry.
pub const default_refresh_buffer_ms = 300_000

/// Messages accepted by the refresh actor.
pub type RefreshMsg {
  Tick
}

type RefreshState {
  RefreshState(
    vault: process.Subject(vault.VaultMsg),
    target_id: String,
    credentials_path: String,
    creds: CodexCredentials,
    /// Credentials that were rotated into the vault but not yet persisted
    /// to disk. Retried before any further refresh so a consumed (and
    /// possibly rotated) refresh token is never lost between restarts.
    pending_write: Option(CodexCredentials),
    check_interval_ms: Int,
    refresh_buffer_ms: Int,
    subject: process.Subject(RefreshMsg),
  )
}

/// Start the refresh actor for a Codex-authenticated target.
///
/// `creds` is the credential pair currently in the vault for `target_id`
/// (the vault must already hold a `vault.CodexToken` for this id — see
/// `runtime` startup wiring). The vault is addressed by `vault_name` rather
/// than a captured `Subject`: under `rest_for_one` supervision a restarted
/// vault re-registers the name, and the resolved subject routes to the new
/// process so rotation never targets a dead vault.
pub fn start(
  vault_name: process.Name(vault.VaultMsg),
  target_id: String,
  credentials_path: String,
  creds: CodexCredentials,
  check_interval_ms: Int,
  refresh_buffer_ms: Int,
) -> Result(process.Subject(RefreshMsg), actor.StartError) {
  let vault_subject = process.named_subject(vault_name)
  let result =
    actor.new_with_initialiser(
      5000,
      initialise(
        vault_subject,
        target_id,
        credentials_path,
        creds,
        check_interval_ms,
        refresh_buffer_ms,
      ),
    )
    |> actor.on_message(handle_message)
    |> actor.start

  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

fn initialise(
  vault_subject: process.Subject(vault.VaultMsg),
  target_id: String,
  credentials_path: String,
  creds: CodexCredentials,
  check_interval_ms: Int,
  refresh_buffer_ms: Int,
) -> fn(process.Subject(RefreshMsg)) ->
  Result(
    actor.Initialised(RefreshState, RefreshMsg, process.Subject(RefreshMsg)),
    String,
  ) {
  fn(subject) {
    // Check expiry immediately at startup so an already-expiring token
    // is refreshed without waiting for the full check_interval_ms.
    let _ = process.send_after(subject, 0, Tick)

    actor.initialised(RefreshState(
      vault: vault_subject,
      target_id:,
      credentials_path:,
      creds:,
      pending_write: option.None,
      check_interval_ms:,
      refresh_buffer_ms:,
      subject:,
    ))
    |> actor.returning(subject)
    |> Ok
  }
}

fn handle_message(
  state: RefreshState,
  msg: RefreshMsg,
) -> actor.Next(RefreshState, RefreshMsg) {
  case msg {
    Tick -> {
      // Retry any previously failed persist, then refresh if the current
      // credentials are expired. Expiry is checked every tick regardless of
      // a pending write: if the token is expiring, do_refresh produces newer
      // credentials that replace the pending write, so the durable copy
      // catches up and the access token never goes stale while the actor
      // keeps running.
      let state = flush_pending_write(state)
      let now_ms = telemetry.system_time()
      let new_state = case
        codex_credentials.is_expired(state.creds, now_ms, state.refresh_buffer_ms)
      {
        True -> do_refresh(state)
        False -> state
      }
      let _ =
        process.send_after(new_state.subject, new_state.check_interval_ms, Tick)
      actor.continue(new_state)
    }
  }
}

/// Retry persisting credentials whose previous write failed. The pending
/// credentials stay in the actor (and the access token in the vault) so
/// in-flight requests keep working; only the durable copy is retried.
fn flush_pending_write(state: RefreshState) -> RefreshState {
  case state.pending_write {
    option.Some(pending) ->
      case codex_credentials.save(state.credentials_path, pending) {
        Ok(_) -> RefreshState(..state, pending_write: option.None)
        Error(reason) -> {
          logging.log(
            logging.Warning,
            "codex_refresh: failed to persist refreshed credentials: "
              <> reason
              <> " — will retry next tick",
          )
          state
        }
      }
    option.None -> state
  }
}

fn do_refresh(state: RefreshState) -> RefreshState {
  case codex_login.refresh(state.creds.refresh_token) {
    Ok(new_creds) -> {
      vault.rotate_token(state.vault, state.target_id, new_creds.access_token)
      let pending_write =
        case codex_credentials.save(state.credentials_path, new_creds) {
          Ok(_) -> option.None
          Error(reason) -> {
            logging.log(
              logging.Warning,
              "codex_refresh: failed to persist refreshed credentials: "
                <> reason
                <> " — will retry next tick",
            )
            option.Some(new_creds)
          }
        }
      logging.log(
        logging.Info,
        "codex_refresh: refreshed Codex access token for target \""
          <> state.target_id
          <> "\"",
      )
      RefreshState(..state, creds: new_creds, pending_write:)
    }
    Error(reason) -> {
      logging.log(
        logging.Warning,
        "codex_refresh: failed to refresh Codex token for target \""
          <> state.target_id
          <> "\": "
          <> reason
          <> " — will retry next tick",
      )
      state
    }
  }
}
