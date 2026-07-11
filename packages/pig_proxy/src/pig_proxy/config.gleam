//// Configuration for the pig_proxy server.
////
//// A `ProxyConfig` describes the upstream provider(s), credential injection,
//// listening port, and (later) virtual model routes. Built via the builder
//// functions in this module.

import envoy
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A single upstream provider target.
pub type UpstreamTarget {
  UpstreamTarget(
    /// Slug used in virtual routing (e.g. "openai", "ollama", "codex").
    id: String,
    /// Base URL including `/v1` prefix, e.g. "https://api.openai.com/v1".
    base_url: String,
    /// API key injected into forwarded requests. Empty for no-auth providers.
    api_key: String,
    /// Optional Codex OAuth JWT for the Codex Responses route.
    codex_token: Option(String),
    /// Ordered fallback chain — model slugs to try if this target fails.
    fallbacks: List(String),
    /// Whether this target supports tool definitions.
    supports_tools: Bool,
    /// Whether this target supports `response_format: json_object`.
    supports_json_schema: Bool,
  )
}

/// Full proxy configuration.
pub type ProxyConfig {
  ProxyConfig(
    targets: List(UpstreamTarget),
    port: Int,
    /// Max retries for transient errors before failing over.
    max_retries: Int,
    /// Consecutive failures before opening a circuit breaker.
    circuit_threshold: Int,
    /// Cool-down period (ms) before a half-open probe is attempted.
    circuit_cooldown_ms: Int,
  )
}

/// Defaults matching the project's local ollama setup.
pub const default_port = 8080

pub const default_max_retries = 3

pub const default_circuit_threshold = 5

pub const default_circuit_cooldown_ms = 30_000

/// Create a config with sensible defaults and the given targets.
pub fn new(targets: List(UpstreamTarget)) -> ProxyConfig {
  ProxyConfig(
    targets:,
    port: default_port,
    max_retries: default_max_retries,
    circuit_threshold: default_circuit_threshold,
    circuit_cooldown_ms: default_circuit_cooldown_ms,
  )
}

/// Set the listening port.
pub fn with_port(config: ProxyConfig, port: Int) -> ProxyConfig {
  ProxyConfig(..config, port:)
}

/// Set max retries.
pub fn with_max_retries(config: ProxyConfig, max_retries: Int) -> ProxyConfig {
  ProxyConfig(..config, max_retries:)
}

/// A convenience builder for a standard OpenAI-compatible target.
pub fn openai_target(
  id: String,
  base_url: String,
  api_key: String,
) -> UpstreamTarget {
  UpstreamTarget(
    id:,
    base_url:,
    api_key:,
    codex_token: None,
    fallbacks: [],
    supports_tools: True,
    supports_json_schema: True,
  )
}

/// Add a fallback model slug to a target's chain.
pub fn with_fallback(target: UpstreamTarget, slug: String) -> UpstreamTarget {
  UpstreamTarget(..target, fallbacks: list.append(target.fallbacks, [slug]))
}

/// Look up a target by its id slug.
pub fn find_target(config: ProxyConfig, id: String) -> Option(UpstreamTarget) {
  case list.find(config.targets, fn(t) { t.id == id }) {
    Ok(target) -> Some(target)
    Error(_) -> None
  }
}

/// Load a config from environment variables, falling back to defaults.
///
/// Reads:
///   PIG_PROXY_PORT             — listening port (default 8080)
///   OPENAI_COMPAT_BASE_URL     — upstream base URL
///   OPENAI_COMPAT_API_KEY      — upstream API key
///   OPENAI_COMPAT_MODEL        — default model slug
///   OPENAI_COMPAT_CODEX_TOKEN  — optional Codex OAuth JWT
pub fn from_env() -> ProxyConfig {
  let target =
    openai_target(
      "default",
      base_url_env(),
      api_key_env(),
    )
    |> maybe_with_codex_token(codex_token_env())

  new([target])
  |> with_port(port_env())
}

fn base_url_env() -> String {
  envoy.get("OPENAI_COMPAT_BASE_URL")
  |> result.unwrap("http://localhost:11434/v1")
}

fn api_key_env() -> String {
  envoy.get("OPENAI_COMPAT_API_KEY")
  |> result.unwrap("ollama")
}

fn codex_token_env() -> Option(String) {
  case envoy.get("OPENAI_COMPAT_CODEX_TOKEN") {
    Ok(token) -> Some(token)
    Error(_) -> None
  }
}

fn port_env() -> Int {
  case envoy.get("PIG_PROXY_PORT") {
    Ok(port_str) ->
      case int.parse(port_str) {
        Ok(p) -> p
        Error(_) -> default_port
      }
    Error(_) -> default_port
  }
}

fn maybe_with_codex_token(
  target: UpstreamTarget,
  token: Option(String),
) -> UpstreamTarget {
  case token {
    Some(t) -> UpstreamTarget(..target, codex_token: Some(t))
    None -> target
  }
}
