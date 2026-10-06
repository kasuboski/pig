//// Pure parser for the subscription host's explicit environment contract.

import envoy
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import pig_otel
import pig_otel/content/options
import pig_proxy/config as proxy_config

/// Validated proxy routes and an optional host-owned trace destination.
pub type Settings {
  Settings(proxy: proxy_config.ProxyConfig, latitude: Option(Latitude))
}

/// OTLP trace destination. The API key is secret and must never be printed.
pub type Latitude {
  Latitude(endpoint: String, api_key: String, project: String)
}

/// Parse settings from an injectable lookup; errors name variables but never values.
pub fn parse(lookup: fn(String) -> Option(String)) -> Result(Settings, String) {
  use chatgpt <- result.try(csv(lookup, "PIG_CHATGPT_MODELS"))
  use zai <- result.try(csv(lookup, "PIG_ZAI_MODELS"))
  use zai_key <- result.try(required(lookup, "ZAI_API_KEY"))
  use port <- result.try(port(lookup))
  use bind <- result.try(bind(lookup))
  use capture <- result.try(boolean(
    lookup,
    "PIG_PROXY_CAPTURE_CONVERSATION",
    True,
  ))
  use input_source_bytes <- result.try(positive_budget(
    lookup,
    "PIG_PROXY_CAPTURE_INPUT_SOURCE_BYTES",
    4_194_304,
    4_194_304,
  ))
  use input_content_bytes <- result.try(positive_budget(
    lookup,
    "PIG_PROXY_CAPTURE_INPUT_CONTENT_BYTES",
    2_097_152,
    2_097_152,
  ))
  use output_source_bytes <- result.try(positive_budget(
    lookup,
    "PIG_PROXY_CAPTURE_OUTPUT_SOURCE_BYTES",
    4_194_304,
    4_194_304,
  ))
  use output_content_bytes <- result.try(positive_budget(
    lookup,
    "PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES",
    65_536,
    2_097_152,
  ))
  use policy <- result.try(capture_policy(
    capture,
    input_source_bytes,
    input_content_bytes,
    output_source_bytes,
    output_content_bytes,
  ))
  use latitude_enabled <- result.try(boolean(
    lookup,
    "PIG_LATITUDE_ENABLED",
    False,
  ))
  use latitude <- result.try(latitude(lookup, latitude_enabled))
  use codex_token <- result.try(case lookup("OPENAI_COMPAT_CODEX_TOKEN") {
    None -> Ok(None)
    Some(_) ->
      required(lookup, "OPENAI_COMPAT_CODEX_TOKEN")
      |> result.map(Some)
  })
  use codex_base <- result.try(url(
    lookup,
    "PIG_CHATGPT_BASE_URL",
    "https://chatgpt.com/backend-api/codex",
  ))
  use zai_base <- result.try(url(
    lookup,
    "PIG_ZAI_BASE_URL",
    "https://api.z.ai/api/coding/paas/v4",
  ))
  use catalog_url <- result.try(url(
    lookup,
    "PIG_PROXY_MODELS_DEV_URL",
    proxy_config.default_models_dev_url,
  ))
  let codex =
    proxy_config.codex_target("chatgpt", codex_base)
    |> proxy_config.with_provider("openai")
  let z =
    proxy_config.openai_target("zai", zai_base, zai_key)
    |> proxy_config.with_api(pig_otel.ChatCompletions)
    |> proxy_config.with_provider("zai")
  let routes =
    list.map(chatgpt, fn(model) {
      proxy_config.model_route(pig_otel.Responses, model, "chatgpt")
    })
    |> list.append(
      list.map(zai, fn(model) {
        proxy_config.model_route(pig_otel.ChatCompletions, model, "zai")
      }),
    )
  let proxy =
    proxy_config.new([codex, z])
    |> proxy_config.with_routes(routes)
    |> proxy_config.with_bind(bind)
    |> proxy_config.with_port(port)
    |> proxy_config.with_models_dev_url(catalog_url)
    |> proxy_config.with_codex_seed_token(codex_token)
    |> proxy_config.with_tracing(policy)
  Ok(Settings(proxy:, latitude:))
}

/// Read the environment at the IO edge, then delegate to the pure parser.
pub fn from_env() -> Result(Settings, String) {
  parse(fn(key) {
    case envoy.get(key) {
      Ok(value) -> Some(value)
      Error(_) -> None
    }
  })
}

fn csv(
  lookup: fn(String) -> Option(String),
  key: String,
) -> Result(List(String), String) {
  use raw <- result.try(required(lookup, key))
  let entries = string.split(raw, ",") |> list.map(string_trim)
  case list.any(entries, fn(entry) { entry == "" }) {
    True -> Error(key <> " must contain non-empty comma-separated model names")
    False ->
      case has_duplicates(entries) {
        True -> Error(key <> " contains duplicate model names")
        False -> Ok(entries)
      }
  }
}

fn positive_budget(
  lookup: fn(String) -> Option(String),
  key: String,
  default: Int,
  maximum: Int,
) -> Result(Int, String) {
  case lookup(key) {
    None -> Ok(default)
    Some(raw) ->
      case int.parse(string_trim(raw)) {
        Ok(value) if value > 0 && value <= maximum -> Ok(value)
        _ ->
          Error(
            key <> " must be an integer from 1 to " <> int.to_string(maximum),
          )
      }
  }
}

fn capture_policy(
  capture: Bool,
  input_source_bytes: Int,
  input_content_bytes: Int,
  output_source_bytes: Int,
  output_content_bytes: Int,
) -> Result(pig_otel.Policy, String) {
  case capture {
    False -> Ok(pig_otel.MetadataOnly)
    True -> {
      use capture_options <- result.try(
        options.with_direction_limits(
          options.defaults(),
          options.InputLimits(
            source_bytes: input_source_bytes,
            content_bytes: input_content_bytes,
          ),
        )
        |> result.map_error(fn(_) { "invalid input capture budgets" }),
      )
      use capture_options <- result.try(
        options.with_direction_limits(
          capture_options,
          options.OutputLimits(
            source_bytes: output_source_bytes,
            content_bytes: output_content_bytes,
          ),
        )
        |> result.map_error(fn(_) { "invalid output capture budgets" }),
      )
      Ok(pig_otel.Conversation(capture_options))
    }
  }
}

fn has_duplicates(values: List(String)) -> Bool {
  list.length(list.unique(values)) != list.length(values)
}

fn required(
  lookup: fn(String) -> Option(String),
  key: String,
) -> Result(String, String) {
  case lookup(key) {
    Some(value) -> {
      let trimmed = string_trim(value)
      case trimmed {
        "" -> Error(key <> " is required")
        _ ->
          case
            string.contains(trimmed, "\r") || string.contains(trimmed, "\n")
          {
            True -> Error(key <> " must not contain newlines")
            False -> Ok(trimmed)
          }
      }
    }
    None -> Error(key <> " is required")
  }
}

fn port(lookup: fn(String) -> Option(String)) -> Result(Int, String) {
  case lookup("PIG_PROXY_PORT") {
    None -> Ok(8080)
    Some(raw) ->
      case int.parse(string_trim(raw)) {
        Ok(n) if n > 0 && n <= 65_535 -> Ok(n)
        _ -> Error("PIG_PROXY_PORT must be an integer from 1 to 65535")
      }
  }
}

fn bind(lookup: fn(String) -> Option(String)) -> Result(String, String) {
  case lookup("PIG_PROXY_BIND") {
    None -> Ok("127.0.0.1")
    Some(raw) ->
      case string_trim(raw) {
        "127.0.0.1" -> Ok("127.0.0.1")
        "0.0.0.0" -> Ok("0.0.0.0")
        _ -> Error("PIG_PROXY_BIND must be 127.0.0.1 or 0.0.0.0")
      }
  }
}

fn boolean(
  lookup: fn(String) -> Option(String),
  key: String,
  default: Bool,
) -> Result(Bool, String) {
  case lookup(key) {
    None -> Ok(default)
    Some(raw) ->
      case string.lowercase(string_trim(raw)) {
        "true" -> Ok(True)
        "false" -> Ok(False)
        _ -> Error(key <> " must be true or false")
      }
  }
}

fn latitude(
  lookup: fn(String) -> Option(String),
  enabled: Bool,
) -> Result(Option(Latitude), String) {
  case enabled {
    False -> Ok(None)
    True -> {
      use key <- result.try(required(lookup, "LATITUDE_API_KEY"))
      use project <- result.try(required(lookup, "LATITUDE_PROJECT"))
      use endpoint <- result.try(url(
        lookup,
        "PIG_LATITUDE_ENDPOINT",
        "https://ingest.latitude.so/v1/traces",
      ))
      case string.ends_with(endpoint, "/v1/traces") {
        True -> Ok(Some(Latitude(endpoint:, api_key: key, project:)))
        False -> Error("PIG_LATITUDE_ENDPOINT must end in /v1/traces")
      }
    }
  }
}

fn url(
  lookup: fn(String) -> Option(String),
  key: String,
  default: String,
) -> Result(String, String) {
  let value = case lookup(key) {
    Some(value) -> string_trim(value)
    None -> default
  }
  let valid = case uri.parse(value) {
    Ok(parsed) -> {
      let secure = case parsed.scheme, parsed.host {
        Some("https"), Some(host) -> host != ""
        Some("http"), Some("127.0.0.1")
        | Some("http"), Some("localhost")
        | Some("http"), Some("::1")
        -> True
        _, _ -> False
      }
      let port_valid = case parsed.port {
        Some(port) -> port > 0 && port <= 65_535
        None -> True
      }
      secure
      && port_valid
      && parsed.userinfo == None
      && parsed.query == None
      && parsed.fragment == None
      && !string.contains(value, "\r")
      && !string.contains(value, "\n")
    }
    Error(_) -> False
  }
  case valid {
    True -> Ok(value)
    False ->
      Error(
        key
        <> " must be an HTTPS URL or loopback HTTP URL without credentials, query, or fragment",
      )
  }
}

fn string_trim(value: String) -> String {
  string.trim(value)
}
