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
import gleam/option.{None, Some}
import logging
import pig_proxy/config
import pig_proxy/metrics
import pig_proxy/server

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

  let state = server.ServerState(
    config: cfg,
    routes: [],
    metrics: metrics_subject,
  )

  server.start(state)
  process.sleep_forever()
}
