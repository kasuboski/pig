import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/httpc
import gleam/string
import gleeunit
import pig/ai/error
import pig/ai/http as ai_http

pub fn main() -> Nil {
  gleeunit.main()
}

// === build_request tests (pure) ===

pub fn build_request_sets_method_to_post_test() {
  let assert Ok(req) =
    ai_http.build_request(
      "https://api.example.com/v1/chat/completions",
      [],
      "{}",
    )
  assert req.method == http.Post
}

pub fn build_request_sets_body_test() {
  let body = "{\"model\":\"gpt-4\"}"
  let assert Ok(req) =
    ai_http.build_request(
      "https://api.example.com/v1/chat/completions",
      [],
      body,
    )
  assert req.body == body
}

pub fn build_request_sets_url_test() {
  let assert Ok(req) =
    ai_http.build_request("https://api.example.com/v1/chat/completions", [], "")
  assert req.host == "api.example.com"
  assert req.scheme == http.Https
  assert req.path == "/v1/chat/completions"
}

pub fn build_request_sets_headers_test() {
  let headers = [
    #("authorization", "Bearer sk-test"),
    #("content-type", "application/json"),
  ]
  let assert Ok(req) =
    ai_http.build_request("https://api.example.com/v1/test", headers, "")
  assert request.get_header(req, "authorization") == Ok("Bearer sk-test")
  assert request.get_header(req, "content-type") == Ok("application/json")
}

// === map_response tests (pure) ===

pub fn map_response_200_returns_body_test() {
  let resp = response.Response(status: 200, headers: [], body: "{\"ok\":true}")
  assert ai_http.map_response(resp) == Ok("{\"ok\":true}")
}

pub fn map_response_401_returns_api_error_test() {
  let resp = response.Response(status: 401, headers: [], body: "unauthorized")
  assert ai_http.map_response(resp)
    == Error(error.ApiError("HTTP 401: unauthorized"))
}

pub fn map_response_429_returns_rate_limited_test() {
  let resp = response.Response(status: 429, headers: [], body: "slow down")
  assert ai_http.map_response(resp) == Error(error.RateLimited)
}

pub fn map_response_500_returns_api_error_test() {
  let resp =
    response.Response(status: 500, headers: [], body: "internal server error")
  assert ai_http.map_response(resp)
    == Error(error.ApiError("HTTP 500: internal server error"))
}

pub fn map_response_400_returns_api_error_test() {
  let resp = response.Response(status: 400, headers: [], body: "bad request")
  assert ai_http.map_response(resp)
    == Error(error.ApiError("HTTP 400: bad request"))
}

pub fn build_request_invalid_url_returns_error_test() {
  let result = ai_http.build_request("not a url", [], "")
  case result {
    Error(error.ApiError(msg)) -> {
      assert string.contains(msg, "Invalid URL")
      Nil
    }
    _ -> panic as "expected ApiError with 'Invalid URL'"
  }
}

// === map_http_error tests (pure) ===

pub fn map_http_error_timeout_returns_timeout_test() {
  assert ai_http.map_http_error(httpc.ResponseTimeout) == error.Timeout
}

pub fn map_http_error_invalid_utf8_returns_invalid_response_test() {
  assert ai_http.map_http_error(httpc.InvalidUtf8Response)
    == error.InvalidResponse("Response body was not valid UTF-8")
}

pub fn map_http_error_failed_to_connect_returns_api_error_test() {
  let err =
    httpc.FailedToConnect(
      ip4: httpc.Posix(code: "econnrefused"),
      ip6: httpc.Posix(code: "econnrefused"),
    )
  let result = ai_http.map_http_error(err)
  case result {
    error.ApiError(msg) -> {
      assert string.contains(msg, "Failed to connect")
      Nil
    }
    _ -> panic as "expected ApiError with 'Failed to connect'"
  }
}
