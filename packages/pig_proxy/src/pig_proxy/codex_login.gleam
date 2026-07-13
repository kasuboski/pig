//// Interactive Codex (ChatGPT) OAuth login for pig_proxy.
////
//// Runs the same PKCE + local callback flow as the Codex CLI: prints an
//// authorization URL to open in a browser, waits for the OAuth callback
//// on `127.0.0.1:1455`, exchanges the authorization code for tokens, and
//// persists the result via `pig_proxy/codex_credentials` so pig_proxy can
//// use and refresh them without depending on the Codex CLI.
////
//// Run with: `gleam run -m pig_proxy/codex_login`

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
  let url = codex_oauth.authorize_url(pkce, state, redirect_uri, originator)

  let subject = process.new_subject()
  start_callback_server(subject, state)

  io.println(
    "Open this URL in your browser to log in to Codex:\n\n" <> url <> "\n",
  )
  io.println("Waiting for the browser callback on " <> redirect_uri <> " ...")

  case process.receive(subject, callback_wait_ms) {
    Error(_) -> io.println_error("Timed out waiting for the OAuth callback.")
    Ok(CallbackError(reason)) -> io.println_error("Login failed: " <> reason)
    Ok(CallbackOk(code)) -> finish_login(code, pkce.verifier, redirect_uri)
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
  token_response_to_credentials(resp_body)
}

/// Exchange a refresh token for a fresh Codex token pair.
pub fn refresh(refresh_token: String) -> Result(CodexCredentials, String) {
  let body = codex_oauth.refresh_request_body(refresh_token)
  use resp_body <- result.try(post_token(body))
  token_response_to_credentials(resp_body)
}

fn token_response_to_credentials(
  resp_body: String,
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
    refresh_token: token.refresh_token,
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
) -> Nil {
  let handler = fn(req) { handle_callback(req, subject, expected_state) }
  let assert Ok(_) =
    handler
    |> mist.new
    |> mist.port(1455)
    |> mist.bind("127.0.0.1")
    |> mist.start
  Nil
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
