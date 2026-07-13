//// Credential vault: a stateful actor that holds upstream API keys
//// and Codex OAuth tokens, supporting rotation without restart.
////
//// The vault is the single source of truth for injected credentials.
//// The proxy's header-injection layer calls `get_credential` to fetch
//// the current key/token for a target, and a background rotation worker
//// calls `rotate_token` when a Codex JWT is refreshed.

import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/otp/actor
import logging

/// A credential held by the vault.
pub type Credential {
  ApiKey(key: String)
  CodexToken(token: String)
}

/// Messages accepted by the vault actor.
pub type VaultMsg {
  GetCredential(target_id: String, reply_to: process.Subject(CredentialResult))
  RotateToken(target_id: String, new_token: String)
  GetStatus(reply_to: process.Subject(VaultStatus))
}

/// Result of a credential lookup.
pub type CredentialResult {
  CredentialFound(Credential)
  CredentialNotFound
}

/// Snapshot of the vault's state for observability.
pub type VaultStatus {
  VaultStatus(target_count: Int, target_ids: List(String))
}

type VaultState {
  VaultState(credentials: Dict(String, Credential))
}

fn handle_message(state: VaultState, msg: VaultMsg) {
  case msg {
    GetCredential(target_id, reply_to) -> {
      let result = case dict.get(state.credentials, target_id) {
        Ok(cred) -> CredentialFound(cred)
        Error(_) -> CredentialNotFound
      }
      process.send(reply_to, result)
      actor.continue(state)
    }

    RotateToken(target_id, new_token) -> {
      let new_creds = case dict.get(state.credentials, target_id) {
        Ok(CodexToken(_)) ->
          dict.insert(state.credentials, target_id, CodexToken(new_token))
        Ok(ApiKey(_)) -> {
          logging.log(
            logging.Warning,
            "vault: ignoring rotate_token for target \""
              <> target_id
              <> "\" — credential is an ApiKey, not a CodexToken",
          )
          state.credentials
        }
        Error(_) -> {
          logging.log(
            logging.Warning,
            "vault: ignoring rotate_token for unknown target \""
              <> target_id
              <> "\"",
          )
          state.credentials
        }
      }
      actor.continue(VaultState(credentials: new_creds))
    }

    GetStatus(reply_to) -> {
      let ids = dict.keys(state.credentials)
      process.send(
        reply_to,
        VaultStatus(target_count: dict.size(state.credentials), target_ids: ids),
      )
      actor.continue(state)
    }
  }
}

/// Start the vault actor with an initial set of credentials.
pub fn start(
  initial: Dict(String, Credential),
) -> Result(process.Subject(VaultMsg), actor.StartError) {
  let result =
    VaultState(credentials: initial)
    |> actor.new
    |> actor.on_message(handle_message)
    |> actor.start
  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Build the initial credentials dict from a list of target id / credential pairs.
pub fn initial_credentials(
  pairs: List(#(String, Credential)),
) -> Dict(String, Credential) {
  dict.from_list(pairs)
}

/// Synchronously fetch a credential from the vault.
pub fn get_credential(
  vault: process.Subject(VaultMsg),
  target_id: String,
  timeout_ms: Int,
) -> CredentialResult {
  actor.call(vault, waiting: timeout_ms, sending: fn(reply_to) {
    GetCredential(target_id, reply_to)
  })
}

/// Asynchronously rotate a Codex token (fire-and-forget).
pub fn rotate_token(
  vault: process.Subject(VaultMsg),
  target_id: String,
  new_token: String,
) -> Nil {
  process.send(vault, RotateToken(target_id, new_token))
}

/// Get a status snapshot of the vault.
pub fn get_status(
  vault: process.Subject(VaultMsg),
  timeout_ms: Int,
) -> VaultStatus {
  actor.call(vault, waiting: timeout_ms, sending: fn(reply_to) {
    GetStatus(reply_to)
  })
}
