//// Interactive Codex (ChatGPT) OAuth login for pig_proxy.
////
//// Runs the PKCE authorization-code flow the Codex CLI uses, with two ways
//// to receive the authorization code:
////   - default (local): a callback server on 127.0.0.1:1455 that the browser
////     redirects to automatically;
////   - manual (PIG_CODEX_LOGIN_MANUAL=1): for remote/headless hosts where the
////     browser can't reach localhost — you paste the redirect URL after
////     authorizing, and the code is parsed + exchanged here.
////
//// Either way the code is exchanged for tokens and persisted via
//// `pig_proxy/codex_credentials`, so pig_proxy can use and refresh them
//// without depending on the Codex CLI.
////
//// Run with: `mise run codex-login` (or `gleam run -m pig_proxy/codex_login`
//// from `packages/pig_proxy`). Add `PIG_CODEX_LOGIN_MANUAL=1` for the paste flow.

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
import gleam/string
import mist
import pig_protocol/auth
import pig_protocol/oauth/codex as codex_oauth
import pig_proxy/codex_credentials.{type CodexCredentials, CodexCredentials}
import pig_proxy/hackney
import pig_proxy/telemetry

@external(erlang, "pig_proxy_io_ffi", "read_line")
fn read_line(prompt: String) -> String

/// Select the manual paste flow (for remote/headless hosts).
fn is_manual() -> Bool {
  case envoy.get("PIG_CODEX_LOGIN_MANUAL") {
    Ok("1") -> True
    Ok("true") -> True
    _ -> False
  }
}

const originator = "pig"

const callback_wait_ms = 300_000

type CallbackResult {
  CallbackOk(code: String)
  CallbackError(reason: String)
}

pub fn main() -> Nil {
  let pkce = codex_oauth.generate_pkce()
  let state = codex_oauth.generate_state()
  let redirect_uri = codex_oauth.default_redirect_uri
  let verifier = codex_oauth.verifier(pkce)
  let url = codex_oauth.authorize_url(pkce, state, redirect_uri, originator)

  case is_manual() {
    True -> run_manual(url, state, verifier, redirect_uri)
    False -> run_callback(url, state, verifier, redirect_uri)
  }
  Nil
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
        <> "  Re-run with PIG_CODEX_LOGIN_MANUAL=1 to paste the redirect URL\n"
        <> "  instead (no port/tunnel needed).",
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
          <> " — is the port already in use? Set PIG_CODEX_LOGIN_MANUAL=1 for the paste flow.",
      )
  }
}

/// Manual paste flow: for remote/headless hosts where the browser can't reach
/// `localhost:1455`. The user authorizes in their browser, copies the
/// resulting redirect URL (which won't load), and pastes it here; the code is
/// parsed out (reusing `parse_callback_query`) and exchanged.
fn run_manual(
  url: String,
  state: String,
  verifier: String,
  redirect_uri: String,
) -> Nil {
  io.println(
    "Open this URL in your browser to log in to Codex:\n\n" <> url <> "\n",
  )
  io.println(
    "Manual mode. After you authorize, your browser is redirected to\n"
      <> redirect_uri
      <> "?code=... — that page will NOT load (expected on a remote host).\n"
      <> "Copy the ENTIRE URL from the browser address bar and paste it below.",
  )
  let pasted = read_line("\nPaste the redirect URL here: ") |> string.trim
  case string.split_once(pasted, "?") {
    Error(_) ->
      io.println_error(
        "That URL has no query — paste the full redirect URL including the '?code=...'.",
      )
    Ok(#(_, query)) ->
      case codex_oauth.parse_callback_query(query) {
        Error(Nil) ->
          io.println_error("Could not find code/state in the URL's query.")
        Ok(#(code, cb_state)) ->
          case cb_state == state {
            False ->
              io.println_error("Login failed: state mismatch (restart the login).")
            True -> finish_login(code, verifier, redirect_uri)
          }
      }
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
