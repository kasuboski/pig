import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit
import pig_proxy/vault

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Setup ───────────────────────────────────────────────────────

fn setup() -> process.Subject(vault.VaultMsg) {
  let creds = vault.initial_credentials([
    #("openai", vault.ApiKey("sk-key")),
    #("codex", vault.CodexToken("jwt-token")),
  ])
  let assert Ok(v) = vault.start(creds)
  v
}

// ── get_credential ──────────────────────────────────────────────

pub fn get_credential_returns_api_key_for_known_target_test() {
  let v = setup()
  let result = vault.get_credential(v, "openai", 2000)
  let assert vault.CredentialFound(vault.ApiKey("sk-key")) = result
}

pub fn get_credential_returns_codex_token_for_known_target_test() {
  let v = setup()
  let result = vault.get_credential(v, "codex", 2000)
  let assert vault.CredentialFound(vault.CodexToken("jwt-token")) = result
}

pub fn get_credential_returns_not_found_for_unknown_target_test() {
  let v = setup()
  let result = vault.get_credential(v, "nonexistent", 2000)
  assert vault.CredentialNotFound == result
}

// ── rotate_token ────────────────────────────────────────────────

pub fn rotate_token_replaces_codex_token_test() {
  let v = setup()
  vault.rotate_token(v, "codex", "new-jwt")
  // Synchronize: get_credential uses actor.call (sync), so the async
  // rotate_token message is processed before the get_credential reply.
  let result = vault.get_credential(v, "codex", 2000)
  let assert vault.CredentialFound(vault.CodexToken("new-jwt")) = result
}

pub fn rotate_token_does_not_replace_api_key_test() {
  let v = setup()
  vault.rotate_token(v, "openai", "should-be-ignored")
  // The vault should NOT replace an ApiKey with a CodexToken.
  let result = vault.get_credential(v, "openai", 2000)
  let assert vault.CredentialFound(vault.ApiKey("sk-key")) = result
}

pub fn rotate_token_for_unknown_target_does_nothing_test() {
  let v = setup()
  vault.rotate_token(v, "unknown", "new-jwt")
  // The vault should NOT create a new entry for an unknown target.
  let result = vault.get_credential(v, "unknown", 2000)
  assert vault.CredentialNotFound == result
}

// ── get_status ──────────────────────────────────────────────────

pub fn get_status_returns_correct_count_and_ids_test() {
  let v = setup()
  let status = vault.get_status(v, 2000)
  assert status.target_count == 2
  let sorted_ids = list.sort(status.target_ids, by: string.compare)
  assert sorted_ids == ["codex", "openai"]
}
