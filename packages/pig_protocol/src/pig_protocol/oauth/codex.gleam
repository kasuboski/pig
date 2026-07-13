//// OpenAI Codex (ChatGPT) OAuth PKCE flow — pure request/response
//// construction.
////
//// This mirrors the OAuth client used by the official Codex CLI and IDE
//// extensions so that pig_proxy can obtain and refresh Codex credentials
//// itself, without shelling out to `codex login`.
////
//// No network access happens in this module. Callers (e.g.
//// `pig_proxy/codex_login`, `pig_proxy/codex_refresh`) build a request
//// with the functions here, execute it with their own HTTP client, and
//// feed the response body back into `parse_token_response`.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/uri

/// The public Codex CLI OAuth client id. Shared by the official Codex CLI
/// and IDE extensions — it is a public PKCE client with no client secret.
pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann"

pub const auth_base_url = "https://auth.openai.com"

const authorize_path = "/oauth/authorize"

const token_path = "/oauth/token"

pub const scope = "openid profile email offline_access"

/// Default local callback address used by the Codex CLI, `pi`, and
/// pig_proxy's login flow. Codex's registered redirect URI is fixed to
/// this value, so a custom port cannot be used.
pub const default_redirect_uri = "http://localhost:1455/auth/callback"

/// The OAuth token endpoint.
pub fn token_url() -> String {
  auth_base_url <> token_path
}

/// A PKCE verifier/challenge pair (RFC 7636).
pub type Pkce {
  Pkce(verifier: String, challenge: String)
}

/// Generate a fresh PKCE verifier and its SHA-256 challenge.
///
/// Uses a cryptographically secure RNG, so despite taking no arguments
/// this function is not pure — each call produces different output.
pub fn generate_pkce() -> Pkce {
  let verifier = random_url_safe_token(32)
  let challenge =
    verifier
    |> bit_array.from_string
    |> crypto.hash(crypto.Sha256, _)
    |> bit_array.base64_url_encode(False)
  Pkce(verifier:, challenge:)
}

/// Generate a random CSRF state token for the authorization request.
pub fn generate_state() -> String {
  random_url_safe_token(16)
}

fn random_url_safe_token(byte_count: Int) -> String {
  crypto.strong_random_bytes(byte_count)
  |> bit_array.base64_url_encode(False)
}

/// Build the browser authorization URL for a login attempt.
///
/// `originator` identifies the calling application to OpenAI (the Codex
/// CLI uses `"codex_cli_rs"`; pig_proxy should use its own name).
pub fn authorize_url(
  pkce: Pkce,
  state: String,
  redirect_uri: String,
  originator: String,
) -> String {
  let query =
    uri.query_to_string([
      #("response_type", "code"),
      #("client_id", client_id),
      #("redirect_uri", redirect_uri),
      #("scope", scope),
      #("code_challenge", pkce.challenge),
      #("code_challenge_method", "S256"),
      #("state", state),
      #("id_token_add_organizations", "true"),
      #("codex_cli_simplified_flow", "true"),
      #("originator", originator),
    ])
  auth_base_url <> authorize_path <> "?" <> query
}

/// Content-type header value required by the token endpoint.
pub const token_request_content_type = "application/x-www-form-urlencoded"

/// Form-encoded body for exchanging an authorization code for tokens.
pub fn exchange_request_body(
  code: String,
  verifier: String,
  redirect_uri: String,
) -> String {
  uri.query_to_string([
    #("grant_type", "authorization_code"),
    #("client_id", client_id),
    #("code", code),
    #("code_verifier", verifier),
    #("redirect_uri", redirect_uri),
  ])
}

/// Form-encoded body for refreshing an access token.
pub fn refresh_request_body(refresh_token: String) -> String {
  uri.query_to_string([
    #("grant_type", "refresh_token"),
    #("refresh_token", refresh_token),
    #("client_id", client_id),
  ])
}

/// A parsed OAuth token endpoint response.
pub type TokenResponse {
  TokenResponse(access_token: String, refresh_token: String, expires_in: Int)
}

fn token_response_decoder() -> decode.Decoder(TokenResponse) {
  use access_token <- decode.field("access_token", decode.string)
  use refresh_token <- decode.field("refresh_token", decode.string)
  use expires_in <- decode.field("expires_in", decode.int)
  decode.success(TokenResponse(access_token:, refresh_token:, expires_in:))
}

/// Parse a token (or refresh) endpoint JSON response body.
pub fn parse_token_response(
  body: String,
) -> Result(TokenResponse, json.DecodeError) {
  json.parse(from: body, using: token_response_decoder())
}

/// Parse `code` and `state` out of a local callback's query string (the
/// part of the request after `?`).
pub fn parse_callback_query(query: String) -> Result(#(String, String), Nil) {
  use params <- result.try(
    uri.parse_query(query) |> result.replace_error(Nil),
  )
  use code <- result.try(list.key_find(params, "code"))
  use state <- result.try(list.key_find(params, "state"))
  Ok(#(code, state))
}
