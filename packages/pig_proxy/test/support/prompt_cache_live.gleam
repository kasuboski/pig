//// Explicitly launched by scripts/validate_prompt_cache_live.sh, never by tests.

import envoy
import gleam/erlang/process
import gleam/int
import gleam/result
import pig_proxy/compatibility
import pig_proxy/config
import pig_proxy/runtime
import pig_proxy/server

pub fn main() -> Nil {
  let assert Ok(base) = envoy.get("OPENAI_COMPAT_BASE_URL")
  let key = result.unwrap(envoy.get("OPENAI_COMPAT_API_KEY"), "")
  let assert Ok(port_text) = envoy.get("PIG_PROXY_PORT")
  let assert Ok(port) = int.parse(port_text)
  let policy = case envoy.get("PROMPT_CACHE_POLICY") {
    Ok("omit") -> compatibility.Omit
    _ -> compatibility.Preserve
  }
  let target =
    config.openai_target("live", base, key)
    |> config.with_model_prompt_cache_options("gpt-6-luna", policy)
  let cfg =
    config.new([target])
    |> config.with_port(port)
    |> config.with_retries_per_target(0)
    |> config.with_models_dev_url("http://127.0.0.1:1/disabled")
  let state = runtime.start(cfg)
  server.start(state)
  process.sleep_forever()
}
