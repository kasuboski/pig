//// Standalone executable proxy server for the pig agent ecosystem.
////
//// An OpenRouter-style LLM proxy that:
////   - Strips client credentials and injects upstream keys (security perimeter).
////   - Pipes SSE streaming responses in real time without buffering.
////   - Retries transient failures with exponential backoff and jitter.
////   - Opens circuit breakers on consecutive upstream failures.
////   - Routes virtual model slugs to active provider fallback chains.
////   - Emits typed telemetry events and exposes a Prometheus `/metrics` endpoint.
////
//// Start with default config from environment variables:
////
////   ```gleam
////   pig_proxy.main()
////   ```
////
//// Or programmatically — `runtime.start` brings up the actors (metrics,
//// catalog, circuit, credential vault + refresh) and returns the
//// `ServerState`, which `server.start` serves:
////
////   ```gleam
////   pig_proxy.config.from_env()
////   |> pig_proxy.runtime.start
////   |> pig_proxy.server.start
////   ```

import gleam/erlang/process
import pig_proxy/config
import pig_proxy/runtime
import pig_proxy/server

/// Entry point: load config from the environment, bring up the proxy
/// runtime (actors + supervision), serve, and block forever.
pub fn main() -> Nil {
  let state = runtime.start(config.from_env())
  server.start(state)
  process.sleep_forever()
}
