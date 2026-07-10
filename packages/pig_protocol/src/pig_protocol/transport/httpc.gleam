import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/result
import logging
import pig_protocol/error.{type AiError}
import pig_protocol/transport.{type HttpRequest}

/// Default HTTP timeout for LLM API calls (120 seconds).
pub const default_timeout_ms = 120_000

/// A `Transport` backed by `gleam_httpc`.
///
/// Use this when you want the protocol package to perform the actual network
/// request. For testing or custom HTTP clients, supply your own `Transport`.
pub fn transport(req: HttpRequest) -> Result(String, AiError) {
  logging.log(logging.Debug, "POST " <> req.url)
  use http_req <- result.try(build_request(req.url, req.headers, req.body))
  let config =
    httpc.configure()
    |> httpc.timeout(req.timeout_ms)
  use resp <- result.try(
    httpc.dispatch(config, http_req)
    |> result.map_error(map_http_error),
  )
  logging.log(logging.Debug, "Response: HTTP " <> int.to_string(resp.status))
  map_response(resp)
}

/// Build a POST request from URL, headers, and body.
/// Pure — no network IO. Returns Error if URL is malformed.
fn build_request(
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Result(Request(String), AiError) {
  case request.to(url) {
    Ok(req) ->
      Ok(
        req
        |> request.set_method(http.Post)
        |> set_headers(headers)
        |> request.set_body(body),
      )
    Error(_) -> Error(error.ApiError("Invalid URL: " <> url))
  }
}

/// Map an HTTP response to a Result(String, AiError).
/// 2xx -> Ok(body), 429 -> RateLimited, other -> ApiError.
/// Pure — no network IO.
fn map_response(resp: Response(String)) -> Result(String, AiError) {
  case resp.status {
    s if s >= 200 && s < 300 -> Ok(resp.body)
    429 -> Error(error.RateLimited)
    status ->
      Error(error.ApiError(
        "HTTP " <> int.to_string(status) <> ": " <> resp.body,
      ))
  }
}

/// Map a gleam_httpc transport error to AiError.
/// Pure — no network IO.
fn map_http_error(err: httpc.HttpError) -> AiError {
  case err {
    httpc.ResponseTimeout -> error.Timeout
    httpc.InvalidUtf8Response ->
      error.InvalidResponse("Response body was not valid UTF-8")
    httpc.FailedToConnect(..) ->
      error.ApiError("Failed to connect: " <> format_connect_error(err))
  }
}

fn set_headers(
  req: Request(String),
  headers: List(#(String, String)),
) -> Request(String) {
  case headers {
    [] -> req
    [#(key, value), ..rest] ->
      req
      |> request.set_header(key, value)
      |> set_headers(rest)
  }
}

fn format_connect_error(err: httpc.HttpError) -> String {
  case err {
    httpc.FailedToConnect(ip4:, ip6:) ->
      "ipv4="
      <> format_socket_error(ip4)
      <> " ipv6="
      <> format_socket_error(ip6)
    _ -> "unknown connection error"
  }
}

fn format_socket_error(err: httpc.ConnectError) -> String {
  case err {
    httpc.Posix(code:) -> code
    httpc.TlsAlert(code:, detail:) -> code <> ": " <> detail
  }
}
