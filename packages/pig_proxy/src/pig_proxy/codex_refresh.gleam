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
    check_interval_ms: Int,
    refresh_buffer_ms: Int,
    subject: process.Subject(RefreshMsg),
  )
}

/// Start the refresh actor for a Codex-authenticated target.
///
/// `creds` is the credential pair currently in the vault for `target_id`
/// (the vault must already hold a `vault.CodexToken` for this id — see
/// `pig_proxy.gleam`'s startup wiring).
pub fn start(
  vault_subject: process.Subject(vault.VaultMsg),
  target_id: String,
  credentials_path: String,
  creds: CodexCredentials,
  check_interval_ms: Int,
  refresh_buffer_ms: Int,
) -> Result(process.Subject(RefreshMsg), actor.StartError) {
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
    let _ = process.send_after(subject, check_interval_ms, Tick)

    actor.initialised(RefreshState(
      vault: vault_subject,
      target_id:,
      credentials_path:,
      creds:,
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
      let now_ms = telemetry.system_time()
      let new_state = case
        codex_credentials.is_expired(
          state.creds,
          now_ms,
          state.refresh_buffer_ms,
        )
      {
        True -> do_refresh(state)
        False -> state
      }
      let _ =
        process.send_after(state.subject, state.check_interval_ms, Tick)
      actor.continue(new_state)
    }
  }
}

fn do_refresh(state: RefreshState) -> RefreshState {
  case codex_login.refresh(state.creds.refresh_token) {
    Ok(new_creds) -> {
      vault.rotate_token(state.vault, state.target_id, new_creds.access_token)
      case codex_credentials.save(state.credentials_path, new_creds) {
        Ok(_) -> Nil
        Error(reason) ->
          logging.log(
            logging.Warning,
            "codex_refresh: failed to persist refreshed credentials: "
              <> reason,
          )
      }
      logging.log(
        logging.Info,
        "codex_refresh: refreshed Codex access token for target \""
          <> state.target_id
          <> "\"",
      )
      RefreshState(..state, creds: new_creds)
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
