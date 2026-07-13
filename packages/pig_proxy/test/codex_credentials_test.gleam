import gleeunit
import pig_proxy/codex_credentials.{
  type CodexCredentials, CodexCredentials,
}
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

const test_path = "/tmp/pig_codex_credentials_test.json"

fn sample_creds() -> CodexCredentials {
  CodexCredentials(
    access_token: "access-abc",
    refresh_token: "refresh-xyz",
    expires_at_ms: 1_700_000_000_000,
    account_id: "acct-123",
  )
}

fn cleanup() -> Nil {
  let _ = simplifile.delete(test_path)
  Nil
}

// ── save / load round-trip ──────────────────────────────────────

pub fn save_then_load_returns_same_credentials_test() {
  cleanup()
  let creds = sample_creds()
  let assert Ok(Nil) = codex_credentials.save(test_path, creds)
  let assert Ok(loaded) = codex_credentials.load(test_path)
  let assert "access-abc" = loaded.access_token
  let assert "refresh-xyz" = loaded.refresh_token
  let assert 1_700_000_000_000 = loaded.expires_at_ms
  let assert "acct-123" = loaded.account_id
  cleanup()
}

pub fn save_creates_parent_directory_test() {
  cleanup()
  let path = "/tmp/pig_test_subdir/codex_auth.json"
  let creds = sample_creds()
  let assert Ok(Nil) = codex_credentials.save(path, creds)
  let assert Ok(_) = codex_credentials.load(path)
  let _ = simplifile.delete(path)
  let _ = simplifile.delete("/tmp/pig_test_subdir")
  Nil
}

// ── load failure ────────────────────────────────────────────────

pub fn load_returns_error_when_file_missing_test() {
  cleanup()
  let assert Error(_) = codex_credentials.load(test_path)
}

// ── is_expired ──────────────────────────────────────────────────

pub fn is_expired_true_when_past_expiry_test() {
  let creds = sample_creds()
  // now is after expiry
  let assert True = codex_credentials.is_expired(creds, 1_700_000_001_000, 0)
}

pub fn is_expired_false_when_within_buffer_test() {
  let creds = sample_creds()
  // now + buffer is before expiry
  let assert False =
    codex_credentials.is_expired(creds, 1_699_000_000_000, 300_000)
}

pub fn is_expired_true_when_within_buffer_of_expiry_test() {
  let creds = sample_creds()
  // now + buffer == expiry exactly → expired
  let assert True =
    codex_credentials.is_expired(creds, 1_699_999_700_000, 300_000)
}

pub fn is_expired_false_when_well_before_expiry_test() {
  let creds = sample_creds()
  let assert False =
    codex_credentials.is_expired(creds, 1_600_000_000_000, 300_000)
}
