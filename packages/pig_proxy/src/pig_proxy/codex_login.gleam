//// Interactive Codex (ChatGPT) OAuth login for pig_proxy.
////
//// Uses OpenAI's device authorization flow by default: open a URL in any
//// browser, enter a short code, and this process polls for authorization.
//// It works identically on local and remote/headless hosts — no localhost
//// callback, tunnel, or pasted redirect URL is needed.
////
//// Set `PIG_CODEX_LOGIN_BROWSER=1` to use the optional local browser
//// callback on 127.0.0.1:1455 instead. Both flows exchange the resulting
//// authorization code for tokens and persist them via
//// `pig_proxy/codex_credentials`, so pig_proxy can use and refresh them
//// without depending on the Codex CLI.
////
//// Run with: `mise run codex-login` (or `gleam run -m pig_proxy/codex_login`
//// from `packages/pig_proxy`).

import envoy
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/result
import mist
import pig_protocol/auth
import pig_protocol/oauth/codex as codex_oauth
import pig_proxy/codex_credentials.{type CodexCredentials, CodexCredentials}
import pig_proxy/hackney
import pig_proxy/telemetry

/// Select the local browser-callback flow instead of the default device flow.
fn is_browser() -> Bool {
  case envoy.get("PIG_CODEX_LOGIN_BROWSER") {
    Ok("1") -> True
    Ok("true") -> True
    _ -> False
  }
}

const originator = "pig"

const callback_wait_ms = 300_000

const device_request_timeout_ms = 30_000

const slow_down_ms = 5_000

type CallbackResult {
  CallbackOk(code: String)
  CallbackError(reason: String)
}

type DevicePollResult {
  DeviceAuthorized(code: String, verifier: String)
  DevicePending
  DeviceSlowDown
  DeviceFailed(reason: String)
}

pub fn main() -> Nil {
  case is_browser() {
    True -> run_browser()
    False -> run_device()
  }
}

/// Default headless-safe flow: visit OpenAI's device page and enter a code.
fn run_device() -> Nil {
  case request_device_usercode() {
    Error(reason) -> io.println_error("Could not start device login: " <> reason)
    Ok(device) -> {
      io.println(
        "Open this URL in any browser and enter this code:\n\n"
          <> "  "
          <> codex_oauth.device_verification_uri
          <> "\n\n  "
          <> device.user_code
          <> "\n",
      )
      io.println("Waiting for OpenAI authorization…")
      poll_device(
        device,
        poll_interval_ms(device.interval_seconds),
        codex_oauth.device_code_timeout_seconds * 1000,
      )
    }
  }
}

fn poll_device(
  device: codex_oauth.DeviceUserCode,
  delay_ms: Int,
  remaining_ms: Int,
) -> Nil {
  case remaining_ms <= 0 {
    True -> io.println_error("Timed out waiting for device authorization.")
    False -> {
      process.sleep(delay_ms)
      case poll_device_token(device) {
        DeviceAuthorized(code:, verifier:) ->
          finish_login(code, verifier, codex_oauth.device_redirect_uri)
        DevicePending -> poll_device(device, delay_ms, remaining_ms - delay_ms)
        DeviceSlowDown ->
          poll_device(device, delay_ms + slow_down_ms, remaining_ms - delay_ms)
        DeviceFailed(reason) -> io.println_error("Device login failed: " <> reason)
      }
    }
  }
}

fn poll_interval_ms(interval_seconds: Int) -> Int {
  case interval_seconds > 0 {
    True -> interval_seconds * 1000
    // Never spin when a malformed response supplies zero.
    False -> 1000
  }
}

fn request_device_usercode() -> Result(codex_oauth.DeviceUserCode, String) {
  hackney.ensure_started()
  case
    hackney.sync_request(
      "POST",
      codex_oauth.device_usercode_url(),
      [#("content-type", codex_oauth.device_request_content_type)],
      codex_oauth.device_usercode_body(),
      device_request_timeout_ms,
    )
  {
    hackney.OkResponse(status: 200, body:, ..) -> {
      use text <- result.try(body_as_string(body))
      codex_oauth.parse_device_usercode(text)
      |> result.map_error(fn(_) { "malformed device-code response" })
    }
    hackney.OkResponse(status:, ..) ->
      Error("device-code endpoint returned status " <> int.to_string(status))
    hackney.ErrorResponse(reason:) -> Error(reason)
  }
}

fn poll_device_token(device: codex_oauth.DeviceUserCode) -> DevicePollResult {
  hackney.ensure_started()
  case
    hackney.sync_request(
      "POST",
      codex_oauth.device_token_url(),
      [#("content-type", codex_oauth.device_request_content_type)],
      codex_oauth.device_token_body(device.device_auth_id, device.user_code),
      device_request_timeout_ms,
    )
  {
    hackney.OkResponse(status: 200, body:, ..) ->
      case body_as_string(body) {
        Error(reason) -> DeviceFailed(reason)
        Ok(text) ->
          case codex_oauth.parse_device_token_success(text) {
            Ok(token) ->
              DeviceAuthorized(token.authorization_code, token.code_verifier)
            Error(_) -> DeviceFailed("malformed device authorization response")
          }
      }
    hackney.OkResponse(status: 403, ..) -> DevicePending
    hackney.OkResponse(status: 404, ..) -> DevicePending
    hackney.OkResponse(status:, body:, ..) -> {
      let text = result.unwrap(body_as_string(body), "")
      case codex_oauth.device_error_code(text) {
        Some("deviceauth_authorization_pending") -> DevicePending
        Some("slow_down") -> DeviceSlowDown
        Some(code) ->
          DeviceFailed(
            "device authorization returned " <> int.to_string(status) <> ": " <> code,
          )
        None ->
          DeviceFailed("device authorization returned status " <> int.to_string(status))
      }
    }
    hackney.ErrorResponse(reason:) -> DeviceFailed(reason)
  }
}

fn body_as_string(body: BitArray) -> Result(String, String) {
  bit_array.to_string(body)
  |> result.map_error(fn(_) { "response is not valid UTF-8" })
}

/// Local callback flow: the browser redirect hits 127.0.0.1:1455 automatically.
fn run_browser() -> Nil {
  let pkce = codex_oauth.generate_pkce()
  let state = codex_oauth.generate_state()
  let redirect_uri = codex_oauth.default_redirect_uri
  let verifier = codex_oauth.verifier(pkce)
  let url = codex_oauth.authorize_url(pkce, state, redirect_uri, originator)
  run_callback(url, state, verifier, redirect_uri)
}

/// Local callback flow: the browser redirect hits 127.0.0.1:1455 automatically.
fn run_callback(
  url: String,
  state: String,
  verifier: String,
  redirect_uri: String,
) -> Nil {
  let subject = process.new_subject()
  case start_callback_server(subject, state) {
    Ok(_) -> {
      io.println(
        "Open this URL in your browser to log in to Codex:\n\n" <> url <> "\n",
      )
      io.println(
        "Waiting for the browser callback on "
          <> redirect_uri
          <> " ...\n"
          <> "  On a remote/headless host the browser can't reach this callback.\n"
          <> "  Re-run without PIG_CODEX_LOGIN_BROWSER to use device-code login\n"
          <> "  instead (no port or tunnel needed).",
      )

      case process.receive(subject, callback_wait_ms) {
        Error(_) -> io.println_error("Timed out waiting for the OAuth callback.")
        Ok(CallbackError(reason)) ->
          io.println_error("Login failed: " <> reason)
        Ok(CallbackOk(code)) -> finish_login(code, verifier, redirect_uri)
      }
    }
    Error(_) ->
      io.println_error(
        "Failed to start the OAuth callback server on 127.0.0.1:1455"
          <> " — is the port already in use? Run the default device-code login instead.",
      )
  }
}

fn finish_login(code: String, verifier: String, redirect_uri: String) -> Nil {
  case exchange_code(code, verifier, redirect_uri) {
    Error(reason) -> io.println_error("Login failed: " <> reason)
    Ok(creds) -> {
      let path = codex_credentials.default_path()
      case codex_credentials.save(path, creds) {
        Ok(_) ->
          io.println(
            "Logged in as account "
            <> creds.account_id
            <> ". Saved credentials to "
            <> path,
          )
        Error(reason) ->
          io.println_error("Failed to save credentials: " <> reason)
      }
    }
  }
}

/// Exchange an authorization code for a Codex token pair and resolve the
/// account id from the resulting JWT. Exposed so `pig_proxy/codex_refresh`
/// can share the same token-parsing logic for refresh requests.
pub fn exchange_code(
  code: String,
  verifier: String,
  redirect_uri: String,
) -> Result(CodexCredentials, String) {
  let body = codex_oauth.exchange_request_body(code, verifier, redirect_uri)
  use resp_body <- result.try(post_token(body))
  token_response_to_credentials(resp_body, "")
}

/// Exchange a refresh token for a fresh Codex token pair.
pub fn refresh(refresh_token: String) -> Result(CodexCredentials, String) {
  let body = codex_oauth.refresh_request_body(refresh_token)
  use resp_body <- result.try(post_token(body))
  // RFC 6749 §6: a refresh response may omit refresh_token; retain the
  // one we just used so the next refresh can proceed.
  token_response_to_credentials(resp_body, refresh_token)
}

fn token_response_to_credentials(
  resp_body: String,
  fallback_refresh_token: String,
) -> Result(CodexCredentials, String) {
  use token <- result.try(
    codex_oauth.parse_token_response(resp_body)
    |> result.map_error(fn(_) { "malformed token response" }),
  )
  use account_id <- result.try(
    auth.account_id_from_jwt(token.access_token)
    |> result.map_error(fn(_) {
      "token response missing chatgpt_account_id claim"
    }),
  )
  let now_ms = telemetry.system_time()
  Ok(CodexCredentials(
    access_token: token.access_token,
    refresh_token: option.unwrap(token.refresh_token, fallback_refresh_token),
    expires_at_ms: now_ms + token.expires_in * 1000,
    account_id:,
  ))
}

fn post_token(body: String) -> Result(String, String) {
  hackney.ensure_started()
  case
    hackney.sync_request(
      "POST",
      codex_oauth.token_url(),
      [#("content-type", codex_oauth.token_request_content_type)],
      body,
      30_000,
    )
  {
    hackney.OkResponse(status: 200, body: resp_body, ..) ->
      case bit_array.to_string(resp_body) {
        Ok(text) -> Ok(text)
        Error(_) -> Error("token response is not valid UTF-8")
      }
    hackney.OkResponse(status:, ..) ->
      Error("token endpoint returned status " <> int.to_string(status))
    hackney.ErrorResponse(reason:) -> Error(reason)
  }
}

// ── Local callback server ────────────────────────────────────────

fn start_callback_server(
  subject: process.Subject(CallbackResult),
  expected_state: String,
) -> Result(Nil, Nil) {
  let handler = fn(req) { handle_callback(req, subject, expected_state) }
  case
    handler
    |> mist.new
    |> mist.port(1455)
    |> mist.bind("127.0.0.1")
    |> mist.start
  {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(Nil)
  }
}

fn handle_callback(
  req: request.Request(mist.Connection),
  subject: process.Subject(CallbackResult),
  expected_state: String,
) -> response.Response(mist.ResponseData) {
  case req.method, request.path_segments(req) {
    http.Get, ["auth", "callback"] ->
      handle_callback_query(req, subject, expected_state)
    _, _ -> html_response(404, error_html("Not found."))
  }
}

fn handle_callback_query(
  req: request.Request(mist.Connection),
  subject: process.Subject(CallbackResult),
  expected_state: String,
) -> response.Response(mist.ResponseData) {
  let params = result.unwrap(request.get_query(req), [])
  case find_param(params, "code"), find_param(params, "state") {
    Some(code), Some(state) if state == expected_state -> {
      process.send(subject, CallbackOk(code))
      html_response(
        200,
        success_html("OpenAI authentication completed. You can close this window."),
      )
    }
    Some(_), Some(_) -> {
      process.send(subject, CallbackError("state mismatch"))
      html_response(400, error_html("State mismatch."))
    }
    _, _ -> {
      process.send(subject, CallbackError("missing authorization code"))
      html_response(400, error_html("Missing authorization code."))
    }
  }
}

fn find_param(params: List(#(String, String)), key: String) -> option.Option(String) {
  case params {
    [] -> None
    [#(k, v), ..rest] ->
      case k == key {
        True -> Some(v)
        False -> find_param(rest, key)
      }
  }
}

fn html_response(
  status: Int,
  body: String,
) -> response.Response(mist.ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn success_html(message: String) -> String {
  "<html><body><h3>" <> message <> "</h3></body></html>"
}

fn error_html(message: String) -> String {
  "<html><body><h3>Login failed</h3><p>" <> message <> "</p></body></html>"
}
