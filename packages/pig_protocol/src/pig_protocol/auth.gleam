import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/string
import pig_protocol/error.{type AiError, InvalidResponse}

/// How to reach an OpenAI-shaped backend.
///
/// `StandardApi` targets the classic `/v1/chat/completions` (and `/v1/responses`)
/// platform route. `CodexOAuth` targets the ChatGPT Plus/Enterprise
/// `chatgpt.com/backend-api/codex/responses` route using a JWT access token.
pub type EndpointMode {
  StandardApi(api_key: String, base_url: String)
  CodexOAuth(access_token: String, base_url: String)
}

/// Trim trailing slashes from a base URL.
fn trim_slash(url: String) -> String {
  case string.ends_with(url, "/") {
    True -> trim_slash(string.drop_end(url, 1))
    False -> url
  }
}

/// Resolve the URL for the Chat Completions endpoint.
///
/// Standard API: `base_url <> "/chat/completions"`.
/// Codex mode: falls back to the Responses endpoint because Codex does not
/// expose a Chat Completions route.
pub fn chat_url(mode: EndpointMode) -> String {
  case mode {
    StandardApi(base_url:, ..) -> trim_slash(base_url) <> "/chat/completions"
    CodexOAuth(..) -> responses_url(mode)
  }
}

/// Resolve the URL for the Responses API endpoint.
///
/// Standard API: `base_url <> "/responses"`.
/// Codex mode: `base_url` normalized to end with `/codex/responses`.
pub fn responses_url(mode: EndpointMode) -> String {
  case mode {
    StandardApi(base_url:, ..) -> {
      let base = trim_slash(base_url)
      case string.ends_with(base, "/responses") {
        True -> base
        False -> base <> "/responses"
      }
    }
    CodexOAuth(base_url:, ..) -> {
      let base = trim_slash(base_url)
      case string.ends_with(base, "/codex/responses") {
        True -> base
        False ->
          case string.ends_with(base, "/codex") {
            True -> base <> "/responses"
            False -> base <> "/codex/responses"
          }
      }
    }
  }
}

/// Build request headers for the given endpoint mode.
///
/// Standard API emits `Authorization: Bearer <api_key>` and JSON content headers.
/// Codex OAuth derives `chatgpt-account-id` from the JWT and adds the required
/// Responses API beta headers.
pub fn headers(
  mode: EndpointMode,
  streaming: Bool,
) -> Result(List(#(String, String)), AiError) {
  let accept = case streaming {
    True -> "text/event-stream"
    False -> "application/json"
  }
  case mode {
    StandardApi(api_key:, ..) ->
      Ok([
        #("authorization", "Bearer " <> api_key),
        #("content-type", "application/json"),
        #("accept", accept),
      ])

    CodexOAuth(access_token:, ..) -> {
      use account_id <- result.try(account_id_from_jwt(access_token))
      Ok([
        #("authorization", "Bearer " <> access_token),
        #("content-type", "application/json"),
        #("accept", accept),
        #("chatgpt-account-id", account_id),
        #("OpenAI-Beta", "responses=experimental"),
        #("originator", "pig"),
      ])
    }
  }
}

/// Extract the ChatGPT account ID from a Codex JWT access token.
///
/// The account ID lives under the claim `https://api.openai.com/auth.chatgpt_account_id`.
/// The token is expected to be a standard three-part JWT; any malformed token
/// returns an `InvalidResponse` error.
pub fn account_id_from_jwt(token: String) -> Result(String, AiError) {
  case string.split(token, ".") {
    [_, payload, _] -> {
      use bits <- result.try(
        bit_array.base64_url_decode(payload)
        |> result.map_error(fn(_) {
          InvalidResponse("Failed to base64-decode JWT payload")
        }),
      )
      use decoded <- result.try(
        bit_array.to_string(bits)
        |> result.map_error(fn(_) {
          InvalidResponse("JWT payload is not valid UTF-8")
        }),
      )
      let account_decoder =
        decode.at(
          ["https://api.openai.com/auth", "chatgpt_account_id"],
          decode.string,
        )
      json.parse(from: decoded, using: account_decoder)
      |> result.map_error(fn(_) {
        InvalidResponse("JWT is missing chatgpt_account_id claim")
      })
    }
    _ -> Error(InvalidResponse("JWT access token must have three dot-separated parts"))
  }
}

/// Resolve whether the token looks like a Codex JWT (has three parts).
pub fn is_jwt(token: String) -> Bool {
  case string.split(token, ".") {
    [_, _, _] -> True
    _ -> False
  }
}
