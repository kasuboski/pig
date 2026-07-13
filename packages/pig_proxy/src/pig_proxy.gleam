//// Standalone executable proxy server for the pig agent ecosystem.
////
//// An OpenRouter-style LLM proxy that:
////   - Strips client credentials and injects upstream keys (security perimeter).
////   - Pipes SSE streaming responses in real time without buffering.
////   - Retries transient failures with exponential backoff and jitter.
////   - Opens circuit breakers on consecutive upstream failures.
////   - Routes virtual model slugs to active provider fallback chains.
////   - Emits `:telemetry` events and exposes a Prometheus `/metrics` endpoint.
////
//// Start with default config from environment variables:
////
////   ```gleam
////   pig_proxy.main()
////   ```
////
//// Or programmatically:
////
////   ```gleam
////   pig_proxy.config.from_env()
////   |> pig_proxy.server.start
////   ```

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import logging
import pig_proxy/codex_credentials
import pig_proxy/codex_refresh
import pig_proxy/config
import pig_proxy/metrics
import pig_proxy/model_catalog
import pig_proxy/server
import pig_proxy/vault

/// Entry point: load config from environment, start metrics aggregator,
/// and start the server.
pub fn main() -> Nil {
  let cfg = config.from_env()

  // Start the background metrics aggregator.
  // It attaches as a telemetry handler and consumes proxy events.
  let metrics_subject = case metrics.start() {
    Ok(#(subject, _handler_id)) -> Some(subject)
    Error(_) -> {
      logging.log(
        logging.Warning,
        "failed to start metrics aggregator — /metrics endpoint disabled",
      )
      None
    }
  }

  // Start the live models.dev catalog refresher.
  let catalog_subject = case model_catalog.start(
    cfg.models_dev_url,
    cfg.models_refresh_ms,
  ) {
    Ok(subject) -> Some(subject)
    Error(_) -> {
      logging.log(
        logging.Warning,
        "failed to start model catalog — cost metrics will be zero",
      )
      None
    }
  }

  // Bootstrap the credential vault from persisted Codex credentials and
  // start the background refresh actor so access tokens stay valid
  // without depending on the Codex CLI. See `pig_proxy/codex_login` for
  // how to obtain the initial credential pair.
  let #(vault_subject, _refresh_subject) = bootstrap_codex_credentials(cfg)

  let state = server.ServerState(
    config: cfg,
    routes: [],
    metrics: metrics_subject,
    catalog: catalog_subject,
    vault: vault_subject,
  )

  server.start(state)
  process.sleep_forever()
}

/// Load persisted Codex credentials from disk (if present) and wire them
/// into the credential vault + background refresh actor. Returns the
/// vault subject (or `None` if no credentials were found) and the refresh
/// actor subject (or `None`).
fn bootstrap_codex_credentials(
  cfg: config.ProxyConfig,
) -> #(
  option.Option(process.Subject(vault.VaultMsg)),
  option.Option(process.Subject(codex_refresh.RefreshMsg)),
) {
  let path = codex_credentials.default_path()
  case codex_credentials.load(path) {
    Ok(creds) -> {
      // Find the target that should receive the Codex credential: prefer
      // one already carrying a `codex_token`, otherwise the env-provided
      // `OPENAI_COMPAT_CODEX_TOKEN` target, otherwise the first target.
      let target_id =
        find_codex_target_id(cfg)
        |> option.unwrap("default")

      let initial =
        vault
        .initial_credentials([#(target_id, vault.CodexToken(creds.access_token))])
      case vault.start(initial) {
        Ok(v) -> {
          case
            codex_refresh.start(
              v,
              target_id,
              path,
              creds,
              codex_refresh.default_check_interval_ms,
              codex_refresh.default_refresh_buffer_ms,
            )
          {
            Ok(refresh) -> #(Some(v), Some(refresh))
            Error(_) -> {
              logging.log(
                logging.Warning,
                "failed to start Codex token refresh actor — tokens will not"
                  <> " be refreshed automatically",
              )
              #(Some(v), None)
            }
          }
        }
        Error(_) -> {
          logging.log(
            logging.Warning,
            "failed to start credential vault — live credential rotation"
              <> " disabled",
          )
          #(None, None)
        }
      }
    }
    Error(reason) -> {
      logging.log(
        logging.Warning,
        "could not load Codex credentials from "
          <> path
          <> ": "
          <> reason
          <> " — live Codex token rotation disabled",
      )
      #(None, None)
    }
  }
}

/// Find the target id that should hold the Codex credential: the first
/// target with a non-None `codex_token`, or the first target overall as
/// a fallback.
fn find_codex_target_id(cfg: config.ProxyConfig) -> option.Option(String) {
  case list.find(cfg.targets, fn(t) { t.codex_token != None }) {
    Ok(t) -> Some(t.id)
    Error(_) ->
      case list.first(cfg.targets) {
        Ok(t) -> Some(t.id)
        Error(_) -> None
      }
  }
}
