import gleam/list
import gleam/option.{None, Some}
import gleeunit
import pig_proxy/config
import pig_proxy/hackney
import pig_proxy/proxy

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Header scrubbing ────────────────────────────────────────────

pub fn scrub_headers_strips_authorization_test() {
  let headers = [
    #("authorization", "Bearer sk-client-secret"),
    #("x-request-id", "abc-123"),
  ]
  let result = proxy.scrub_headers(headers)
  assert result == [#("x-request-id", "abc-123")]
}

pub fn scrub_headers_strips_api_key_header_test() {
  let headers = [
    #("api-key", "sk-secret"),
    #("x-request-id", "abc-123"),
  ]
  let result = proxy.scrub_headers(headers)
  assert result == [#("x-request-id", "abc-123")]
}

pub fn scrub_headers_strips_host_and_connection_test() {
  let headers = [
    #("host", "proxy:8080"),
    #("connection", "keep-alive"),
    #("content-length", "42"),
    #("transfer-encoding", "chunked"),
    #("content-type", "application/json"),
    #("accept", "application/json"),
    #("x-request-id", "abc-123"),
  ]
  let result = proxy.scrub_headers(headers)
  assert result == [#("x-request-id", "abc-123")]
}

pub fn scrub_headers_is_case_insensitive_test() {
  let headers = [
    #("Authorization", "Bearer sk-secret"),
    #("API-KEY", "sk-secret"),
    #("Content-Type", "application/json"),
    #("Accept", "application/json"),
    #("x-request-id", "abc-123"),
  ]
  let result = proxy.scrub_headers(headers)
  assert result == [#("x-request-id", "abc-123")]
}

// ── Credential injection ────────────────────────────────────────

pub fn inject_api_key_prepends_bearer_test() {
  let headers = [#("content-type", "application/json")]
  let result = proxy.inject_api_key(headers, "sk-test-key")
  assert list.first(result) == Ok(#("authorization", "Bearer sk-test-key"))
  assert list.length(result) == 2
}

// ── URL resolution ──────────────────────────────────────────────

pub fn resolve_upstream_url_chat_completions_test() {
  let target = config.openai_target("test", "https://api.openai.com/v1", "key")
  let url = proxy.resolve_upstream_url(target, "/v1/chat/completions")
  assert url == "https://api.openai.com/v1/chat/completions"
}

pub fn resolve_upstream_url_responses_test() {
  let target = config.openai_target("test", "https://api.openai.com/v1", "key")
  let url = proxy.resolve_upstream_url(target, "/v1/responses")
  assert url == "https://api.openai.com/v1/responses"
}

pub fn resolve_upstream_url_trims_trailing_slash_test() {
  let target = config.openai_target("test", "https://api.openai.com/v1/", "key")
  let url = proxy.resolve_upstream_url(target, "/v1/chat/completions")
  assert url == "https://api.openai.com/v1/chat/completions"
}

pub fn resolve_upstream_url_local_ollama_test() {
  let target =
    config.openai_target("ollama", "http://localhost:11434/v1", "ollama")
  let url = proxy.resolve_upstream_url(target, "/v1/chat/completions")
  assert url == "http://localhost:11434/v1/chat/completions"
}

// ── Request body inspection ─────────────────────────────────────

pub fn is_streaming_true_test() {
  let body = "{\"model\":\"gpt-4o\",\"stream\":true}"
  assert proxy.is_streaming(body) == True
}

pub fn is_streaming_false_test() {
  let body = "{\"model\":\"gpt-4o\",\"stream\":false}"
  assert proxy.is_streaming(body) == False
}

pub fn is_streaming_absent_defaults_false_test() {
  let body = "{\"model\":\"gpt-4o\"}"
  assert proxy.is_streaming(body) == False
}

pub fn is_streaming_malformed_json_defaults_false_test() {
  let body = "not json at all"
  assert proxy.is_streaming(body) == False
}

pub fn extract_model_present_test() {
  let body = "{\"model\":\"gpt-4o\",\"stream\":true}"
  assert proxy.extract_model(body) == "gpt-4o"
}

pub fn extract_model_absent_returns_unknown_test() {
  let body = "{\"stream\":true}"
  assert proxy.extract_model(body) == "unknown"
}

// ── Config ──────────────────────────────────────────────────────

pub fn config_new_has_defaults_test() {
  let cfg = config.new([config.openai_target("a", "http://x/v1", "k")])
  assert cfg.port == config.default_port
  assert cfg.max_retries == config.default_max_retries
  assert cfg.circuit_threshold == config.default_circuit_threshold
  assert cfg.circuit_cooldown_ms == config.default_circuit_cooldown_ms
}

pub fn config_with_port_test() {
  let cfg =
    config.new([config.openai_target("a", "http://x/v1", "k")])
    |> config.with_port(9999)
  assert cfg.port == 9999
}

pub fn config_find_target_existing_test() {
  let cfg =
    config.new([
      config.openai_target("openai", "http://x/v1", "k"),
      config.openai_target("ollama", "http://y/v1", "k2"),
    ])
  let assert Some(target) = config.find_target(cfg, "ollama")
  assert target.id == "ollama"
}

pub fn config_find_target_missing_returns_none_test() {
  let cfg = config.new([config.openai_target("openai", "http://x/v1", "k")])
  assert config.find_target(cfg, "nonexistent") == None
}

pub fn config_with_fallback_test() {
  let target =
    config.openai_target("openai", "http://x/v1", "k")
    |> config.with_fallback("gpt-4-turbo")
    |> config.with_fallback("llama-3")
  assert target.fallbacks == ["gpt-4-turbo", "llama-3"]
}

// ── Hackney response to mist conversion ─────────────────────────

pub fn sync_response_to_mist_ok_test() {
  let resp = hackney.OkResponse(
    status: 200,
    headers: [#("content-type", "application/json")],
    body: <<123, 125>>,
  )
  let mist_resp = proxy.sync_response_to_mist(resp)
  assert mist_resp.status == 200
}

pub fn sync_response_to_mist_error_returns_502_test() {
  let resp = hackney.ErrorResponse(reason: "connection refused")
  let mist_resp = proxy.sync_response_to_mist(resp)
  assert mist_resp.status == 502
}

// ── Hackney ensure_started ──────────────────────────────────────

pub fn hackney_ensure_started_does_not_crash_test() {
  hackney.ensure_started()
}
