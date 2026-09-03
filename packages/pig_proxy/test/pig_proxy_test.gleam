import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit
import pig_protocol/sse
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
  assert cfg.bind == config.default_bind
  assert cfg.port == config.default_port
  assert cfg.retries_per_target == config.default_retries_per_target
  assert cfg.circuit_threshold == config.default_circuit_threshold
  assert cfg.circuit_cooldown_ms == config.default_circuit_cooldown_ms
}

pub fn config_with_bind_test() {
  let cfg =
    config.new([config.openai_target("a", "http://x/v1", "k")])
    |> config.with_bind("0.0.0.0")
  assert cfg.bind == "0.0.0.0"
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

// ── Target authentication ───────────────────────────────────────

pub fn openai_target_uses_api_key_auth_test() {
  let target = config.openai_target("openai", "http://x/v1", "sk-key")
  assert config.is_codex_target(target) == False
  let assert config.ApiKey(key) = target.auth
  assert key == "sk-key"
}

pub fn codex_target_uses_codex_auth_test() {
  let target =
    config.codex_target("codex", "https://chatgpt.com/backend-api/codex")
  assert config.is_codex_target(target) == True
  let assert config.Codex = target.auth
  Nil
}

pub fn with_codex_marks_target_as_codex_test() {
  let target =
    config.openai_target("openai", "http://x/v1", "sk-key")
    |> config.with_codex
  assert config.is_codex_target(target) == True
}

pub fn build_upstream_headers_api_key_injects_bearer_test() {
  let headers =
    proxy.build_upstream_headers(
      [#("x-request-id", "abc"), #("authorization", "Bearer client-secret")],
      "http://x/v1",
      proxy.ApiKey("sk-upstream"),
      False,
    )
  // Client auth is scrubbed; the upstream key is injected; JSON content
  // and accept headers are added by the proxy.
  assert list.key_find(headers, "authorization") == Ok("Bearer sk-upstream")
  assert list.key_find(headers, "content-type") == Ok("application/json")
  assert list.key_find(headers, "accept") == Ok("application/json")
  assert list.key_find(headers, "x-request-id") == Ok("abc")
}

// ── Hackney response to mist conversion ─────────────────────────

pub fn sync_response_to_mist_ok_test() {
  let resp =
    hackney.OkResponse(
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

// ── Usage extraction ──────────────────────────────────────────

pub fn parse_usage_reads_prompt_and_completion_tokens_test() {
  let body = "{\"usage\":{\"prompt_tokens\":42,\"completion_tokens\":17}}"
  let usage = proxy.parse_usage(body)
  assert usage.prompt == Some(42)
  assert usage.completion == Some(17)
  assert usage.cached == None
}

pub fn parse_usage_reads_chat_cached_tokens_test() {
  let body =
    "{\"usage\":{\"prompt_tokens\":42,\"completion_tokens\":17,\"prompt_tokens_details\":{\"cached_tokens\":40}}}"
  let usage = proxy.parse_usage(body)
  assert usage.prompt == Some(42)
  assert usage.completion == Some(17)
  assert usage.cached == Some(40)
}

pub fn parse_usage_reads_responses_cached_tokens_test() {
  let body =
    "{\"response\":{\"usage\":{\"input_tokens\":100,\"output_tokens\":4,\"input_tokens_details\":{\"cached_tokens\":64}}}}"
  let usage = proxy.parse_usage(body)
  assert usage.prompt == Some(100)
  assert usage.completion == Some(4)
  assert usage.cached == Some(64)
}

pub fn parse_usage_missing_usage_returns_none_test() {
  let body = "{\"id\":\"chatcmpl-123\"}"
  let usage = proxy.parse_usage(body)
  assert usage.prompt == None
  assert usage.completion == None
}

pub fn parse_usage_partial_tokens_test() {
  let body = "{\"usage\":{\"completion_tokens\":9}}"
  let usage = proxy.parse_usage(body)
  assert usage.prompt == None
  assert usage.completion == Some(9)
}

pub fn parse_usage_from_sse_reads_one_completed_frame_test() {
  let frame =
    "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20,\"prompt_tokens_details\":{\"cached_tokens\":6}}}\n\n"
  let usage = proxy.parse_usage_from_sse(frame)
  assert usage.prompt == Some(10)
  assert usage.completion == Some(20)
  assert usage.cached == Some(6)
}

pub fn parse_usage_from_sse_does_not_scan_multiple_frames_test() {
  let frames =
    "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20}}\n\n"
    <> "data: [DONE]\n\n"
  let usage = proxy.parse_usage_from_sse(frames)
  assert usage.prompt == None
  assert usage.completion == None
}

pub fn parse_usage_from_sse_ignores_non_data_lines_test() {
  let frame =
    "event: ping\n\n"
    <> "data: {\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2}}\n\n"
  let usage = proxy.parse_usage_from_sse(frame)
  assert usage.prompt == Some(1)
  assert usage.completion == Some(2)
}

pub fn parse_usage_from_sse_no_usage_returns_none_test() {
  let frame = "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n"
  let usage = proxy.parse_usage_from_sse(frame)
  assert usage.prompt == None
  assert usage.completion == None
}

pub fn usage_framing_handles_multibyte_split_before_terminal_frame_test() {
  let content_frame =
    "data: {\"choices\":[{\"delta\":{\"content\":\"café\"}}]}\n\n"
  let terminal_frame =
    "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":20}}\n\n"
  let stream = bit_array.from_string(content_frame <> terminal_frame)
  let split_at =
    bit_array.byte_size(bit_array.from_string(
      "data: {\"choices\":[{\"delta\":{\"content\":\"caf",
    ))
    + 1
  let assert Ok(first) = bit_array.slice(stream, 0, split_at)
  let assert Ok(second) =
    bit_array.slice(stream, split_at, bit_array.byte_size(stream) - split_at)

  let assert Ok(#(decoder, [])) = sse.push(sse.new(), first)
  let assert Ok(#(decoder_2, [content, terminal])) = sse.push(decoder, second)
  assert content == string.drop_end(content_frame, 2)
  let usage = proxy.parse_usage_from_sse(terminal)
  assert usage.prompt == Some(10)
  assert usage.completion == Some(20)
  let assert Ok([]) = sse.finish(decoder_2)
}

pub fn usage_framing_handles_crlf_frame_test() {
  let frame =
    "event: message\r\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4}}\r\n\r\n"
  let assert Ok(#(decoder, [completed])) =
    sse.push(sse.new(), bit_array.from_string(frame))
  let usage = proxy.parse_usage_from_sse(completed)
  assert usage.prompt == Some(3)
  assert usage.completion == Some(4)
  let assert Ok([]) = sse.finish(decoder)
}

pub fn ensure_stream_usage_injects_include_usage_test() {
  let body = "{\"model\":\"gpt-4o\",\"stream\":true}"
  let result = proxy.ensure_stream_usage(body)
  assert string.contains(result, "\"include_usage\":true")
  assert string.contains(result, "\"stream_options\":")
}

pub fn ensure_stream_usage_preserves_existing_stream_options_test() {
  let body =
    "{\"model\":\"gpt-4o\",\"stream\":true,\"stream_options\":{\"include_usage\":false}}"
  let result = proxy.ensure_stream_usage(body)
  assert string.contains(result, "\"include_usage\":true")
}

pub fn ensure_stream_usage_malformed_body_unchanged_test() {
  let body = "not json"
  assert proxy.ensure_stream_usage(body) == body
}

pub fn ensure_stream_usage_normalizes_non_map_stream_options_test() {
  // A non-map stream_options (null, a list) must be coerced to an object
  // so include_usage injection succeeds instead of being discarded.
  let null_body =
    "{\"model\":\"gpt-4o\",\"stream\":true,\"stream_options\":null}"
  assert string.contains(
    proxy.ensure_stream_usage(null_body),
    "\"include_usage\":true",
  )

  let list_body =
    "{\"model\":\"gpt-4o\",\"stream\":true,\"stream_options\":[1,2]}"
  assert string.contains(
    proxy.ensure_stream_usage(list_body),
    "\"include_usage\":true",
  )
}

// ── Responses API usage parsing ──────────────────────────────

pub fn parse_usage_reads_responses_api_input_output_tokens_test() {
  let body =
    "{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":42,\"output_tokens\":17}}}"
  let usage = proxy.parse_usage(body)
  assert usage.prompt == Some(42)
  assert usage.completion == Some(17)
}

pub fn parse_usage_from_sse_extracts_responses_usage_test() {
  let chunk =
    "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":7,\"output_tokens\":8}}}\n\n"
  let usage = proxy.parse_usage_from_sse(chunk)
  assert usage.prompt == Some(7)
  assert usage.completion == Some(8)
}

// ── Response header filtering ────────────────────────────────

pub fn sync_response_to_mist_strips_connection_nominated_headers_test() {
  let resp =
    hackney.OkResponse(
      status: 200,
      headers: [
        #("content-type", "application/json"),
        #("connection", "x-custom, transfer-encoding"),
        #("x-custom", "should-not-forward"),
      ],
      body: <<123, 125>>,
    )
  let mist_resp = proxy.sync_response_to_mist(resp)
  let found =
    list.find(mist_resp.headers, fn(h) { string.lowercase(h.0) == "x-custom" })
  // x-custom was nominated by the Connection header and must be stripped.
  assert result.is_error(found)
}

// ── Config validation ────────────────────────────────────────

pub fn config_with_models_refresh_ms_rejects_non_positive_test() {
  let zero_cfg = config.new([]) |> config.with_models_refresh_ms(0)
  assert zero_cfg.models_refresh_ms == config.default_models_refresh_ms
  let neg_cfg = config.new([]) |> config.with_models_refresh_ms(-5)
  assert neg_cfg.models_refresh_ms == config.default_models_refresh_ms
  let ok_cfg = config.new([]) |> config.with_models_refresh_ms(90_000)
  assert ok_cfg.models_refresh_ms == 90_000
}
