//// Persisted Codex (ChatGPT) OAuth credentials.
////
//// pig_proxy obtains and refreshes Codex credentials itself (see
//// `pig_proxy/codex_login` and `pig_proxy/codex_refresh`) rather than
//// depending on the Codex CLI's `~/.codex/auth.json`. Credentials are
//// stored as JSON at `PIG_CODEX_AUTH_PATH`, defaulting to
//// `~/.pig/codex_auth.json`, so they survive proxy restarts.

import envoy
import filepath
import gleam/dynamic/decode
import gleam/json
import gleam/result
import simplifile

/// A Codex OAuth access/refresh token pair plus the account it belongs to.
pub type CodexCredentials {
  CodexCredentials(
    access_token: String,
    refresh_token: String,
    /// Unix epoch milliseconds when `access_token` expires.
    expires_at_ms: Int,
    account_id: String,
  )
}

/// Resolve the credentials file path: `PIG_CODEX_AUTH_PATH` if set,
/// otherwise `~/.pig/codex_auth.json`.
pub fn default_path() -> String {
  case envoy.get("PIG_CODEX_AUTH_PATH") {
    Ok(path) -> path
    Error(_) ->
      case envoy.get("HOME") {
        Ok(home) -> filepath.join(home, ".pig/codex_auth.json")
        Error(_) -> "./codex_auth.json"
      }
  }
}

fn decoder() -> decode.Decoder(CodexCredentials) {
  use access_token <- decode.field("access_token", decode.string)
  use refresh_token <- decode.field("refresh_token", decode.string)
  use expires_at_ms <- decode.field("expires_at_ms", decode.int)
  use account_id <- decode.field("account_id", decode.string)
  decode.success(CodexCredentials(
    access_token:,
    refresh_token:,
    expires_at_ms:,
    account_id:,
  ))
}

/// Load credentials from disk.
pub fn load(path: String) -> Result(CodexCredentials, String) {
  use contents <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { "failed to read " <> path }),
  )
  json.parse(from: contents, using: decoder())
  |> result.map_error(fn(_) { "failed to parse " <> path })
}

fn to_json(creds: CodexCredentials) -> String {
  json.object([
    #("access_token", json.string(creds.access_token)),
    #("refresh_token", json.string(creds.refresh_token)),
    #("expires_at_ms", json.int(creds.expires_at_ms)),
    #("account_id", json.string(creds.account_id)),
  ])
  |> json.to_string
}

/// Persist credentials to disk, creating the parent directory if needed.
/// The file is restricted to owner-only permissions (0600) since it
/// contains sensitive OAuth tokens.
pub fn save(path: String, creds: CodexCredentials) -> Result(Nil, String) {
  let dir = filepath.directory_name(path)
  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(_) { "failed to create directory " <> dir }),
  )
  use _ <- result.try(
    simplifile.write(path, to_json(creds))
    |> result.map_error(fn(_) { "failed to write " <> path }),
  )
  simplifile.set_permissions_octal(path, 0o600)
  |> result.map_error(fn(_) { "failed to set permissions on " <> path })
}

/// Whether the access token is already expired or will expire within
/// `buffer_ms` of `now_ms`.
pub fn is_expired(
  creds: CodexCredentials,
  now_ms: Int,
  buffer_ms: Int,
) -> Bool {
  now_ms + buffer_ms >= creds.expires_at_ms
}
