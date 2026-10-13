//// Opt-in real HTTP loopback verification; no external provider required.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/string
import integration/gate
import pig_proxy/compatibility
import pig_proxy/config
import pig_proxy/hackney
import pig_proxy/runtime
import pig_proxy/server

/// Run just this loopback suite without requiring a live Chat Completions model.
pub fn main() -> Nil {
  prompt_cache_policy_is_applied_for_sync_and_streaming_requests_test()
  case gate.skip_unless_enabled() {
    True -> Nil
    False ->
      io.println(
        "PASS: 6 loopback Responses cases (buffered + streaming; 400 forwarding, omission, preservation; exact upstream bodies)",
      )
  }
}

pub fn prompt_cache_policy_is_applied_for_sync_and_streaming_requests_test() {
  case gate.skip_unless_enabled() {
    True -> Nil
    False -> {
      let assert Ok(#(upstream_port, upstream_pid)) = start_capture_upstream()
      let target =
        config.openai_target(
          "loopback",
          "http://127.0.0.1:" <> int.to_string(upstream_port) <> "/v1",
          "test-key",
        )
        |> config.with_model_prompt_cache_options(
          "omit-model",
          compatibility.Omit,
        )
        |> config.with_model_prompt_cache_options(
          "keep-model",
          compatibility.Preserve,
        )
      let cfg =
        config.new([target])
        |> config.with_bind("127.0.0.1")
        |> config.with_port(8092)
        // A 400 must commit even with a retry budget available. Comparing
        // every captured request below detects accidental retries.
        |> config.with_retries_per_target(2)
      let state = runtime.start(cfg)
      let assert Ok(listener) = server.start_managed(state)
      let assert True = gate.wait_until_ready(cfg.port)
      list.each([False, True], fn(streaming) {
        list.each(
          [
            #("pass-model", 400, True),
            #("omit-model", 200, False),
            #("keep-model", 200, True),
          ],
          fn(row) {
            check(cfg.port, upstream_pid, row.0, streaming, row.1, row.2)
          },
        )
      })
      server.stop_managed(listener)
      runtime.stop(state)
      stop_capture_upstream(upstream_pid)
    }
  }
}

fn check(
  port: Int,
  upstream: process.Pid,
  model: String,
  streaming: Bool,
  status: Int,
  retained: Bool,
) {
  let fields = [
    #("model", json.string(model)),
    #("input", json.string("summarize this conversation")),
    #("stream", json.bool(streaming)),
    #("prompt_cache_key", json.string("key")),
    #("prompt_cache_retention", json.string("24h")),
    #("nested", json.object([#("prompt_cache_options", json.bool(True))])),
  ]
  let option = #(
    "prompt_cache_options",
    json.object([#("mode", json.string("explicit"))]),
  )
  let body = json.to_string(json.object([option, ..fields]))
  let assert hackney.OkResponse(status: actual_status, body: response_body, ..) =
    hackney.sync_request(
      "POST",
      "http://127.0.0.1:" <> int.to_string(port) <> "/v1/responses",
      [#("content-type", "application/json")],
      body,
      5000,
    )
  assert actual_status == status
  let assert Ok(response_body) = bit_array.to_string(response_body)
  case status {
    400 -> {
      assert string.contains(response_body, "invalid_parameter")
    }
    _ -> {
      assert string.contains(response_body, "completed")
    }
  }
  let assert Ok(captured) = await_body(upstream)
  case retained {
    True -> {
      assert captured == body
    }
    False -> {
      assert json.parse(captured, decode.dynamic)
        == json.parse(json.to_string(json.object(fields)), decode.dynamic)
    }
  }
}

@external(erlang, "pig_proxy_prompt_cache_compat_test_ffi", "start_capture_upstream")
fn start_capture_upstream() -> Result(#(Int, process.Pid), Nil)

@external(erlang, "pig_proxy_prompt_cache_compat_test_ffi", "await_body")
fn await_body(pid: process.Pid) -> Result(String, Nil)

@external(erlang, "pig_proxy_prompt_cache_compat_test_ffi", "stop_capture_upstream")
fn stop_capture_upstream(pid: process.Pid) -> Nil
