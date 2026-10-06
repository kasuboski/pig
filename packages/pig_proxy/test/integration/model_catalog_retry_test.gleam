//// Gated loopback proof that a failed catalog request is retried and cached.

import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{Some}
import gleeunit
import pig_proxy/model_catalog

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn failed_startup_fetch_is_retried_and_cached_test() {
  case should_skip() {
    True -> Nil
    False -> {
      let assert Ok(#(port, server_pid)) = start_failure_then_success_server()
      let name = process.new_name("model-catalog-retry-integration")
      let assert Ok(started) =
        model_catalog.start_named(
          "http://127.0.0.1:" <> int.to_string(port),
          10_000,
          name,
        )
      let cached = await_cached_model(name, 120)
      stop_failure_then_success_server(started.pid)
      stop_failure_then_success_server(server_pid)
      assert cached
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

fn await_cached_model(
  name: process.Name(model_catalog.CatalogMsg),
  attempts_left: Int,
) -> Bool {
  let catalog = model_catalog.cached(name)
  case model_catalog.find(catalog, "openai/recovered") {
    Some(_) -> True
    _ ->
      case attempts_left <= 0 {
        True -> False
        False -> {
          process.sleep(100)
          await_cached_model(name, attempts_left - 1)
        }
      }
  }
}

@external(erlang, "pig_proxy_model_catalog_retry_test_ffi", "start_failure_then_success_server")
fn start_failure_then_success_server() -> Result(#(Int, process.Pid), Nil)

@external(erlang, "pig_proxy_model_catalog_retry_test_ffi", "stop_failure_then_success_server")
fn stop_failure_then_success_server(pid: process.Pid) -> Nil
