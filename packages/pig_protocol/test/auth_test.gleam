import gleam/bit_array
import gleam/json
import gleam/list
import gleam/string
import gleeunit
import pig_protocol/auth
import pig_protocol/error.{InvalidResponse}

pub fn main() -> Nil {
  gleeunit.main()
}

fn token_with_payload(payload: json.Json) -> String {
  let header = "eyJhbGciOiJub25lIn0"
  let body =
    payload
    |> json.to_string()
    |> bit_array.from_string()
    |> bit_array.base64_url_encode(False)
  header <> "." <> body <> "."
}

fn fake_jwt(account_id: String) -> String {
  token_with_payload(
    json.object([
      #(
        "https://api.openai.com/auth",
        json.object([#("chatgpt_account_id", json.string(account_id))]),
      ),
    ]),
  )
}

// ── URL resolution ────────────────────────────────────────────────

pub fn standard_chat_url_test() {
  let mode = auth.StandardApi("sk-test", "https://api.openai.com/v1")
  assert auth.chat_url(mode) == "https://api.openai.com/v1/chat/completions"
}

pub fn codex_responses_url_test() {
  let mode = auth.CodexOAuth(fake_jwt("x"), "https://chatgpt.com/backend-api")
  assert auth.responses_url(mode) == "https://chatgpt.com/backend-api/codex/responses"
}

pub fn codex_responses_url_with_trailing_slash_test() {
  let mode = auth.CodexOAuth(fake_jwt("x"), "https://chatgpt.com/backend-api/")
  assert auth.responses_url(mode) == "https://chatgpt.com/backend-api/codex/responses"
}

pub fn codex_responses_url_already_normalized_test() {
  let mode = auth.CodexOAuth(fake_jwt("x"), "https://chatgpt.com/backend-api/codex/responses")
  assert auth.responses_url(mode) == "https://chatgpt.com/backend-api/codex/responses"
}

// ── Header generation ───────────────────────────────────────────

pub fn standard_headers_test() {
  let mode = auth.StandardApi("sk-test", "https://api.openai.com/v1")
  let assert Ok(headers) = auth.headers(mode, False)
  assert list_contains(headers, "authorization", "Bearer sk-test")
  assert list_contains(headers, "content-type", "application/json")
  assert list_contains(headers, "accept", "application/json")
}

pub fn standard_streaming_headers_test() {
  let mode = auth.StandardApi("sk-test", "https://api.openai.com/v1")
  let assert Ok(headers) = auth.headers(mode, True)
  assert list_contains(headers, "accept", "text/event-stream")
}

pub fn codex_headers_test() {
  let account_id = "acct_123"
  let token = fake_jwt(account_id)
  let mode = auth.CodexOAuth(token, "https://chatgpt.com/backend-api")
  let assert Ok(headers) = auth.headers(mode, True)
  assert list_contains(headers, "authorization", "Bearer " <> token)
  assert list_contains(headers, "chatgpt-account-id", account_id)
  assert list_contains(headers, "OpenAI-Beta", "responses=experimental")
  assert list_contains(headers, "originator", "pig")
  assert list_contains(headers, "accept", "text/event-stream")
}

pub fn codex_invalid_jwt_returns_error_test() {
  let mode = auth.CodexOAuth("not-a-jwt", "https://chatgpt.com/backend-api")
  let assert Error(InvalidResponse(_)) = auth.headers(mode, False)
}

pub fn codex_jwt_missing_account_id_returns_error_test() {
  let token = token_with_payload(json.object([#("sub", json.string("user-123"))]))
  let mode = auth.CodexOAuth(token, "https://chatgpt.com/backend-api")
  let assert Error(InvalidResponse(_)) = auth.headers(mode, False)
}

// ── Helpers ─────────────────────────────────────────────────────

fn list_contains(
  headers: List(#(String, String)),
  key: String,
  value: String,
) -> Bool {
  list.any(headers, fn(entry) {
    string.lowercase(entry.0) == string.lowercase(key) && entry.1 == value
  })
}
