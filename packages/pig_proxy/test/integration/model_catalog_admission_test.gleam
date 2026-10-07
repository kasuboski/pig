//// Barrier-controlled catalog admission snapshot regression.

import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import pig_proxy/model_catalog

pub fn delayed_publication_does_not_reprice_admitted_inference_test() {
  case should_skip() {
    True -> Nil
    False -> {
      let assert Ok(#(port, server_pid)) = start_gated_catalog_server()
      let name = process.new_name("model-catalog-admission")
      let assert Ok(started) =
        model_catalog.start_named(
          "http://127.0.0.1:" <> int.to_string(port),
          60_000,
          name,
        )

      // The fixture acknowledges the actual catalog HTTP request and withholds
      // its response until explicitly released. No scheduling delay is involved.
      assert await_catalog_request()
      assert model_catalog.await_ready(name, 1) == False
      let admitted =
        model_catalog.pin(model_catalog.cached(name), [#("openai", "priced")])
      assert model_catalog.estimate_pinned(
          admitted,
          "openai",
          "priced",
          Some(1_000_000),
          Some(1_000_000),
          None,
        )
        == model_catalog.Unknown

      release_catalog_response(server_pid)
      assert model_catalog.await_ready(name, 5000)
      assert model_catalog.await_ready(name, 0)
      let later =
        model_catalog.pin(model_catalog.cached(name), [#("openai", "priced")])
      assert model_catalog.estimate_pinned(
          later,
          "openai",
          "priced",
          Some(1_000_000),
          Some(1_000_000),
          None,
        )
        == model_catalog.Complete(2.0, 10.0, 12.0)
      // The first inference's pinned snapshot remains empty by design.
      assert model_catalog.estimate_pinned(
          admitted,
          "openai",
          "priced",
          Some(1_000_000),
          Some(1_000_000),
          None,
        )
        == model_catalog.Unknown

      stop_gated_catalog_server(started.pid)
      stop_gated_catalog_server(server_pid)
      Nil
    }
  }
}

fn should_skip() -> Bool {
  case envoy.get("PIG_RUN_MODEL_CATALOG_INTEGRATION") {
    Ok(_) -> False
    Error(_) -> {
      io.println(
        "[SKIP] model catalog loopback integration (set PIG_RUN_MODEL_CATALOG_INTEGRATION=1)",
      )
      True
    }
  }
}

@external(erlang, "pig_proxy_model_catalog_admission_test_ffi", "start_gated_catalog_server")
fn start_gated_catalog_server() -> Result(#(Int, process.Pid), Nil)

@external(erlang, "pig_proxy_model_catalog_admission_test_ffi", "await_catalog_request")
fn await_catalog_request() -> Bool

@external(erlang, "pig_proxy_model_catalog_admission_test_ffi", "release_catalog_response")
fn release_catalog_response(pid: process.Pid) -> Nil

@external(erlang, "pig_proxy_model_catalog_admission_test_ffi", "stop_gated_catalog_server")
fn stop_gated_catalog_server(pid: process.Pid) -> Nil
