//// Self-contained operational host for ChatGPT and z.ai subscription routes.

import gleam/erlang/process
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/string
import logging
import pig_proxy/codex_credentials
import pig_proxy/runtime
import pig_proxy/server
import subscriptions/config
import subscriptions/lifecycle

/// Run the subscription host until SIGTERM, then stop with a bounded
/// best-effort final export. Configuration failures exit without listening.
pub fn main() -> Nil {
  case config.from_env() {
    Error(message) -> {
      io.println("subscriptions host configuration error: " <> message)
      halt(2)
    }
    Ok(settings) -> start(settings)
  }
}

fn start(settings: config.Settings) -> Nil {
  let config.Settings(proxy:, latitude:) = settings
  case credentials_available(proxy.codex_seed_token) {
    False -> {
      io.println(
        "subscriptions host requires Codex credentials: run `mise run codex-login` or set OPENAI_COMPAT_CODEX_TOKEN",
      )
      halt(2)
    }
    True -> Nil
  }
  lifecycle.clear_otel_environment()
  bootstrap()
  let subject = process.new_subject()
  install_signals(fn() { process.send(subject, ShutdownSignal) })
  case latitude {
    Some(config.Latitude(endpoint:, api_key:, project:)) ->
      configure_latitude(endpoint, api_key, project)
    _ -> Nil
  }
  let state = runtime.start(proxy)
  case server.start_managed(state) {
    Error(message) -> {
      shutdown(fn() { runtime.stop(state) })
      io.println("subscriptions host startup failed: " <> message)
      halt(1)
    }
    Ok(listener) -> {
      logging.log(logging.Info, "subscriptions host started on " <> proxy.bind)
      let _ = process.receive_forever(subject)
      shutdown(fn() {
        server.stop_managed(listener)
        runtime.stop(state)
      })
      halt(0)
    }
  }
}

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

@external(erlang, "pig_subscriptions_host_ffi", "bootstrap")
fn bootstrap() -> Nil

@external(erlang, "pig_subscriptions_host_ffi", "configure_latitude")
fn configure_latitude(endpoint: String, key: String, project: String) -> Nil

fn credentials_available(seed: Option(String)) -> Bool {
  // Match runtime's persisted-first decision, including parse/read failures.
  case codex_credentials.load(codex_credentials.default_path()) {
    Ok(creds) ->
      string.trim(creds.access_token) != ""
      && string.trim(creds.refresh_token) != ""
      && string.trim(creds.account_id) != ""
    Error(_) ->
      case seed {
        Some(token) -> string.trim(token) != ""
        None -> False
      }
  }
}

type ShutdownSignal {
  ShutdownSignal
}

@external(erlang, "pig_subscriptions_host_ffi", "install_signals")
fn install_signals(notify: fn() -> Nil) -> Nil

@external(erlang, "pig_subscriptions_host_ffi", "stop_sdk")
fn stop_sdk() -> Result(Nil, Nil)

fn shutdown(cleanup: fn() -> Nil) -> Nil {
  case
    lifecycle.shutdown(
      cleanup,
      stop_sdk,
      lifecycle.shutdown_timeout_ms,
      lifecycle.sdk_stop_timeout_ms,
    )
  {
    Ok(Nil) -> Nil
    Error(_) -> {
      io.println_error(
        "subscriptions host shutdown failed; trace delivery is not guaranteed",
      )
      halt(1)
    }
  }
}
