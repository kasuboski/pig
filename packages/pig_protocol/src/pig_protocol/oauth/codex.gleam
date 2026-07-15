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
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
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
///
/// Opaque so callers cannot construct mismatched verifier/challenge
/// pairs (which would break the PKCE security guarantee). Use
/// `generate_pkce` to create a pair and `verifier`/`challenge` to read
/// the components.
pub opaque type Pkce {
  Pkce(verifier: String, challenge: String)
}

/// The verifier to send in the token exchange request.
pub fn verifier(pkce: Pkce) -> String {
  pkce.verifier
}

/// The challenge embedded in the authorization URL.
pub fn challenge(pkce: Pkce) -> String {
  pkce.challenge
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
///
/// `refresh_token` is optional: per RFC 6749 §6 the authorization server
/// MAY issue a new refresh token on refresh but is not required to. When
/// absent, callers must retain their existing refresh token.
pub type TokenResponse {
  TokenResponse(
    access_token: String,
    refresh_token: Option(String),
    expires_in: Int,
  )
}

fn token_response_decoder() -> decode.Decoder(TokenResponse) {
  use access_token <- decode.field("access_token", decode.string)
  use refresh_token <- decode.optional_field(
    "refresh_token",
    option.None,
    decode.optional(decode.string),
  )
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

// ── Device authorization flow (headless) ────────────────────────
//
// OpenAI also exposes a device-code flow (the "visit a URL and enter a
// code" UX), which works on remote/headless hosts where the browser can't
// reach a localhost callback. Unlike the browser PKCE flow, the device
// token endpoint returns the authorization code AND its code_verifier, so
// the caller exchanges them at the normal token endpoint with the device
// redirect URI. These device endpoints speak JSON (not form-encoded).

const device_usercode_path = "/api/accounts/deviceauth/usercode"

const device_token_path = "/api/accounts/deviceauth/token"

/// Where the user goes to enter the device code (in any browser).
pub const device_verification_uri = "https://auth.openai.com/codex/device"

/// Redirect URI used in the final code exchange for the device flow.
pub const device_redirect_uri = "https://auth.openai.com/deviceauth/callback"

/// How long a device code is valid (matches the official CLI / pi).
pub const device_code_timeout_seconds = 900

/// Content-type for the device endpoints (JSON, unlike the token endpoint).
pub const device_request_content_type = "application/json"

/// Device user-code request endpoint (`POST` `{client_id}`).
pub fn device_usercode_url() -> String {
  auth_base_url <> device_usercode_path
}

/// Device token polling endpoint.
pub fn device_token_url() -> String {
  auth_base_url <> device_token_path
}

/// JSON body for the device user-code request.
pub fn device_usercode_body() -> String {
  json.to_string(json.object([#("client_id", json.string(client_id))]))
}

/// JSON body for polling the device token endpoint.
pub fn device_token_body(device_auth_id: String, user_code: String) -> String {
  json.to_string(
    json.object([
      #("device_auth_id", json.string(device_auth_id)),
      #("user_code", json.string(user_code)),
    ]),
  )
}

/// A device user-code response: the code to display + how often to poll.
pub type DeviceUserCode {
  DeviceUserCode(
    device_auth_id: String,
    user_code: String,
    interval_seconds: Int,
  )
}

fn device_usercode_decoder() -> decode.Decoder(DeviceUserCode) {
  use device_auth_id <- decode.field("device_auth_id", decode.string)
  use user_code <- decode.field("user_code", decode.string)
  use interval_seconds <- decode.field("interval", device_interval_decoder())
  decode.success(DeviceUserCode(device_auth_id:, user_code:, interval_seconds:))
}

fn device_interval_decoder() -> decode.Decoder(Int) {
  let numeric_string = decode.then(decode.string, fn(value) {
    case int.parse(value) {
      Ok(interval) -> decode.success(interval)
      Error(_) -> decode.failure(0, "integer string")
    }
  })
  let raw = decode.one_of(decode.int, or: [numeric_string])
  decode.then(raw, fn(interval) {
    case interval >= 0 {
      True -> decode.success(interval)
      False -> decode.failure(0, "non-negative interval")
    }
  })
}

/// Parse a device user-code JSON response.
pub fn parse_device_usercode(
  body: String,
) -> Result(DeviceUserCode, json.DecodeError) {
  json.parse(from: body, using: device_usercode_decoder())
}

/// A completed device authorization: the code + verifier to exchange.
pub type DeviceToken {
  DeviceToken(authorization_code: String, code_verifier: String)
}

fn device_token_decoder() -> decode.Decoder(DeviceToken) {
  use authorization_code <- decode.field("authorization_code", decode.string)
  use code_verifier <- decode.field("code_verifier", decode.string)
  decode.success(DeviceToken(authorization_code:, code_verifier:))
}

/// Parse a successful device token JSON response.
pub fn parse_device_token_success(
  body: String,
) -> Result(DeviceToken, json.DecodeError) {
  json.parse(from: body, using: device_token_decoder())
}

/// Extract the error code from a device token error response. The `error`
/// field may be a string or an object with a `code` field; returns the code
/// if either is present (used to tell `deviceauth_authorization_pending` /
/// `slow_down` from a real failure).
pub fn device_error_code(body: String) -> Option(String) {
  let object_code = decode.map(
    decode.at(["error", "code"], decode.string),
    option.Some,
  )
  let string_error = decode.field("error", decode.string, fn(error) {
    decode.success(option.Some(error))
  })
  let decoder =
    decode.one_of(object_code, or: [string_error, decode.success(option.None)])
  result.unwrap(json.parse(from: body, using: decoder), option.None)
}
