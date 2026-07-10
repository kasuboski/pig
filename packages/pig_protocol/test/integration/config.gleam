//// Shared config for pig_protocol integration tests.
////
//// Reads environment variables with defaults for the local
//// ollama-amd provider. All integration tests import from here.

import envoy
import gleam/result

/// Gating variable — must be set to run integration tests.
pub const run_env = "PIG_RUN_INTEGRATION"

/// Check whether integration tests should run.
/// Returns Ok(Nil) if the gate is open, Error(Nil) otherwise.
pub fn should_run() -> Result(Nil, Nil) {
  case envoy.get(run_env) {
    Ok(_) -> Ok(Nil)
    Error(_) -> Error(Nil)
  }
}

/// Get the base URL used for the Chat Completions endpoint.
pub fn base_url() -> String {
  envoy.get("OPENAI_COMPAT_BASE_URL")
  |> result.unwrap("http://100.103.149.97:11434/v1")
}

/// Get the base URL used for the Codex Responses endpoint. Defaults to the
/// Chat Completions base URL so users can point a single local server at both.
pub fn codex_base_url() -> String {
  envoy.get("OPENAI_COMPAT_CODEX_BASE_URL")
  |> result.unwrap(base_url())
}

/// Get the API key. Defaults to "ollama" (ignored by local providers).
pub fn api_key() -> String {
  envoy.get("OPENAI_COMPAT_API_KEY")
  |> result.unwrap("ollama")
}

/// Get the JWT access token used for the Codex Responses test. Empty when
/// unset — the codex integration test will report a clear error in that case.
pub fn codex_token() -> String {
  envoy.get("OPENAI_COMPAT_CODEX_TOKEN")
  |> result.unwrap("")
}

/// Get the model name. Defaults to gemopuse4b.
pub fn model() -> String {
  envoy.get("OPENAI_COMPAT_MODEL")
  |> result.unwrap("gemopuse4b")
}
