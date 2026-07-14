import gleam/option.{None, Some}
import gleam/string
import gleeunit
import pig_protocol/oauth/codex

pub fn main() -> Nil {
  gleeunit.main()
}

// ── PKCE ────────────────────────────────────────────────────────

pub fn generate_pkce_produces_nonempty_verifier_and_challenge_test() {
  let pkce = codex.generate_pkce()
  assert string.length(codex.verifier(pkce)) > 0
  assert string.length(codex.challenge(pkce)) > 0
}

pub fn generate_pkce_verifier_and_challenge_differ_test() {
  let pkce = codex.generate_pkce()
  assert codex.verifier(pkce) != codex.challenge(pkce)
}

pub fn generate_pkce_challenge_has_no_padding_or_plus_slash_test() {
  let pkce = codex.generate_pkce()
  let challenge = codex.challenge(pkce)
  assert !string.contains(challenge, "=")
  assert !string.contains(challenge, "+")
  assert !string.contains(challenge, "/")
}

pub fn generate_pkce_is_random_across_calls_test() {
  let a = codex.generate_pkce()
  let b = codex.generate_pkce()
  assert codex.verifier(a) != codex.verifier(b)
}

// ── generate_state ────────────────────────────────────────────────

pub fn generate_state_is_random_across_calls_test() {
  assert codex.generate_state() != codex.generate_state()
}

// ── authorize_url ───────────────────────────────────────────────

pub fn authorize_url_contains_expected_params_test() {
  let pkce = codex.generate_pkce()
  let url =
    codex.authorize_url(pkce, "state-value", codex.default_redirect_uri, "pig")

  assert string.starts_with(url, codex.auth_base_url <> "/oauth/authorize?")
  assert string.contains(url, "client_id=" <> codex.client_id)
  assert string.contains(url, "code_challenge=" <> codex.challenge(pkce))
  assert string.contains(url, "code_challenge_method=S256")
  assert string.contains(url, "state=state-value")
  assert string.contains(url, "originator=pig")
}

// ── request bodies ──────────────────────────────────────────────

pub fn exchange_request_body_contains_expected_fields_test() {
  let body =
    codex.exchange_request_body(
      "auth-code",
      "verifier-value",
      codex.default_redirect_uri,
    )
  assert string.contains(body, "grant_type=authorization_code")
  assert string.contains(body, "client_id=" <> codex.client_id)
  assert string.contains(body, "code=auth-code")
  assert string.contains(body, "code_verifier=verifier-value")
}

pub fn refresh_request_body_contains_expected_fields_test() {
  let body = codex.refresh_request_body("refresh-token-value")
  assert string.contains(body, "grant_type=refresh_token")
  assert string.contains(body, "refresh_token=refresh-token-value")
  assert string.contains(body, "client_id=" <> codex.client_id)
}

// ── parse_token_response ─────────────────────────────────────────

pub fn parse_token_response_success_test() {
  let body =
    "{\"access_token\":\"a\",\"refresh_token\":\"r\",\"expires_in\":3600}"
  let assert Ok(token) = codex.parse_token_response(body)
  assert token.access_token == "a"
  assert token.refresh_token == Some("r")
  assert token.expires_in == 3600
}

pub fn parse_token_response_omitted_refresh_token_is_ok_test() {
  // RFC 6749 §6: a refresh response may omit refresh_token; it must still
  // decode, leaving refresh_token as None for the caller to backfill.
  let body = "{\"access_token\":\"a\",\"expires_in\":3600}"
  let assert Ok(token) = codex.parse_token_response(body)
  assert token.access_token == "a"
  assert token.refresh_token == None
  assert token.expires_in == 3600
}

pub fn parse_token_response_missing_field_is_error_test() {
  // access_token and expires_in are required; omitting either is an error.
  let body = "{\"access_token\":\"a\"}"
  let assert Error(_) = codex.parse_token_response(body)
}

pub fn parse_token_response_malformed_json_is_error_test() {
  let assert Error(_) = codex.parse_token_response("not json")
}

// ── parse_callback_query ─────────────────────────────────────────

pub fn parse_callback_query_extracts_code_and_state_test() {
  let assert Ok(#(code, state)) =
    codex.parse_callback_query("code=abc123&state=xyz789")
  assert code == "abc123"
  assert state == "xyz789"
}

pub fn parse_callback_query_missing_code_is_error_test() {
  let assert Error(Nil) = codex.parse_callback_query("state=xyz789")
}

pub fn parse_callback_query_missing_state_is_error_test() {
  let assert Error(Nil) = codex.parse_callback_query("code=abc123")
}
