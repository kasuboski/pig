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

/// How an upstream target authenticates: a static API key, or
/// ChatGPT/Codex OAuth whose live token is resolved from the credential
/// vault at request time. One concept per target — the two cannot be mixed.
pub type TargetAuth {
  /// A static key injected as `Authorization: Bearer <key>`.
  ApiKey(key: String)
  /// ChatGPT/Codex OAuth. The live JWT is resolved from the credential
  /// vault (seeded by `pig_proxy/codex_login` or a seed token) so a rotated
  /// token is picked up with no restart.
  Codex
}

/// A single upstream provider target.
pub type UpstreamTarget {
  UpstreamTarget(
    /// Slug used in virtual routing (e.g. "openai", "ollama", "codex").
    id: String,
    /// Base URL including `/v1` prefix, e.g. "https://api.openai.com/v1".
    base_url: String,
    /// How this target authenticates upstream. See `TargetAuth`.
    auth: TargetAuth,
    /// Provider key matching models.dev (e.g. "openai", "anthropic").
    /// When set, telemetry and metrics use `provider/model` as the
    /// model key so cost lookups against the models.dev catalog resolve
    /// correctly. `None` for local or unknown providers.
    provider: Option(String),
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
    /// URL of the models.dev catalog JSON.
    models_dev_url: String,
    /// How often (ms) to refresh the model catalog.
    models_refresh_ms: Int,
    /// Optional static Codex JWT (e.g. from `OPENAI_COMPAT_CODEX_TOKEN`)
    /// used to seed the credential vault at startup when persisted
    /// credentials are unavailable. Request-time auth always flows through
    /// the vault; this never authenticates a request directly.
    codex_seed_token: Option(String),
  )
}

/// Defaults matching the project's local ollama setup.
pub const default_port = 8080

pub const default_max_retries = 3

pub const default_circuit_threshold = 5

pub const default_circuit_cooldown_ms = 30_000

pub const default_models_dev_url = "https://models.dev/api.json"

pub const default_models_refresh_ms = 3600_000

/// Create a config with sensible defaults and the given targets.
pub fn new(targets: List(UpstreamTarget)) -> ProxyConfig {
  ProxyConfig(
    targets:,
    port: default_port,
    max_retries: default_max_retries,
    circuit_threshold: default_circuit_threshold,
    circuit_cooldown_ms: default_circuit_cooldown_ms,
    models_dev_url: default_models_dev_url,
    models_refresh_ms: default_models_refresh_ms,
    codex_seed_token: None,
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

/// Set the models.dev catalog URL.
pub fn with_models_dev_url(config: ProxyConfig, url: String) -> ProxyConfig {
  ProxyConfig(..config, models_dev_url: url)
}

/// Set the model catalog refresh interval in milliseconds.
/// Non-positive values are replaced with the default refresh interval so
/// a misconfigured env var cannot starve the actor into a tight refresh
/// loop.
pub fn with_models_refresh_ms(config: ProxyConfig, ms: Int) -> ProxyConfig {
  let effective = case ms <= 0 {
    True -> default_models_refresh_ms
    False -> ms
  }
  ProxyConfig(..config, models_refresh_ms: effective)
}

/// Set the static Codex seed token used to bootstrap the credential vault.
pub fn with_codex_seed_token(
  config: ProxyConfig,
  token: Option(String),
) -> ProxyConfig {
  ProxyConfig(..config, codex_seed_token: token)
}

/// A convenience builder for a standard OpenAI-compatible target that
/// authenticates with a static API key.
pub fn openai_target(
  id: String,
  base_url: String,
  api_key: String,
) -> UpstreamTarget {
  UpstreamTarget(
    id:,
    base_url:,
    auth: ApiKey(api_key),
    provider: None,
    fallbacks: [],
    supports_tools: True,
    supports_json_schema: True,
  )
}

/// A convenience builder for a ChatGPT/Codex OAuth target. The live token
/// is resolved from the credential vault at request time rather than held
/// statically on the target.
pub fn codex_target(id: String, base_url: String) -> UpstreamTarget {
  UpstreamTarget(
    id:,
    base_url:,
    auth: Codex,
    provider: None,
    fallbacks: [],
    supports_tools: True,
    supports_json_schema: True,
  )
}

/// Mark a target as authenticating via ChatGPT/Codex OAuth. Its live token
/// is then resolved from the credential vault instead of a static key.
pub fn with_codex(target: UpstreamTarget) -> UpstreamTarget {
  UpstreamTarget(..target, auth: Codex)
}

/// Whether a target authenticates via ChatGPT/Codex OAuth.
pub fn is_codex_target(target: UpstreamTarget) -> Bool {
  case target.auth {
    Codex -> True
    ApiKey(_) -> False
  }
}

/// Set the provider key (matches models.dev, e.g. "openai", "anthropic").
/// Enables provider-prefixed model keys in telemetry and metrics for
/// correct cost lookups against the models.dev catalog.
pub fn with_provider(
  target: UpstreamTarget,
  provider: String,
) -> UpstreamTarget {
  UpstreamTarget(..target, provider: Some(provider))
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

/// Extract the provider string from a target, or empty string if unset.
/// Used by telemetry to build the `provider/model` metrics key.
pub fn provider_string(target: UpstreamTarget) -> String {
  case target.provider {
    Some(p) -> p
    None -> ""
  }
}

/// Load a config from environment variables, falling back to defaults.
///
/// Reads:
///   PIG_PROXY_PORT                  — listening port (default 8080)
///   OPENAI_COMPAT_BASE_URL          — upstream base URL
///   OPENAI_COMPAT_API_KEY           — upstream API key
///   OPENAI_COMPAT_MODEL             — default model slug
///   OPENAI_COMPAT_CODEX             — mark the default target as ChatGPT/Codex OAuth
///   OPENAI_COMPAT_CODEX_TOKEN       — optional Codex OAuth JWT (seeds the vault)
///   OPENAI_COMPAT_PROVIDER          — models.dev provider key (e.g. "openai")
///   PIG_PROXY_MODELS_DEV_URL        — models.dev catalog URL
///   PIG_PROXY_MODELS_REFRESH_MS     — catalog refresh interval in ms
pub fn from_env() -> ProxyConfig {
  let codex_token = codex_token_env()
  let is_codex = codex_env() || codex_token != None
  let target =
    case is_codex {
      True -> codex_target("default", base_url_env())
      False -> openai_target("default", base_url_env(), api_key_env())
    }
    |> maybe_with_provider(provider_env())

  new([target])
  |> with_port(port_env())
  |> with_models_dev_url(models_dev_url_env())
  |> with_models_refresh_ms(models_refresh_ms_env())
  |> with_codex_seed_token(codex_token)
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

fn codex_env() -> Bool {
  case envoy.get("OPENAI_COMPAT_CODEX") {
    Ok("true") -> True
    Ok("1") -> True
    _ -> False
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

fn models_dev_url_env() -> String {
  envoy.get("PIG_PROXY_MODELS_DEV_URL")
  |> result.unwrap(default_models_dev_url)
}

fn models_refresh_ms_env() -> Int {
  case envoy.get("PIG_PROXY_MODELS_REFRESH_MS") {
    Ok(ms_str) ->
      case int.parse(ms_str) {
        Ok(ms) -> ms
        Error(_) -> default_models_refresh_ms
      }
    Error(_) -> default_models_refresh_ms
  }
}

fn maybe_with_provider(
  target: UpstreamTarget,
  provider: Option(String),
) -> UpstreamTarget {
  case provider {
    Some(p) -> UpstreamTarget(..target, provider: Some(p))
    None -> target
  }
}

fn provider_env() -> Option(String) {
  case envoy.get("OPENAI_COMPAT_PROVIDER") {
    Ok(p) -> Some(p)
    Error(_) -> None
  }
}
