import gleeunit
import pig/openai

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn provider_with_default_base_url_test() {
  let openai.OpenAIProvider(config:, call: _) =
    openai.provider("sk-test", "gpt-4o")
  let assert True =
    config.base_url == "https://api.openai.com/v1"
    && config.api_key == "sk-test"
    && config.model == "gpt-4o"
}

pub fn provider_with_custom_base_url_test() {
  let openai.OpenAIProvider(config:, call: _) =
    openai.provider_with_base_url(
      "key",
      "qwen3:0.6b",
      "http://localhost:11434/v1",
    )
  let assert True =
    config.base_url == "http://localhost:11434/v1"
    && config.model == "qwen3:0.6b"
}

pub fn provider_with_base_url_and_timeout_test() {
  let openai.OpenAIProvider(config:, call: _) =
    openai.provider_with_base_url_and_timeout(
      "sk-test",
      "gpt-4o",
      "http://localhost:11434/v1",
      30_000,
    )
  let assert True =
    config.api_key == "sk-test"
    && config.model == "gpt-4o"
    && config.base_url == "http://localhost:11434/v1"
    && config.http_timeout_ms == 30_000
}

pub fn with_http_timeout_overrides_test() {
  let original =
    openai.provider_with_base_url(
      "sk-test",
      "gpt-4o",
      "http://localhost:11434/v1",
    )
  let openai.OpenAIProvider(config: updated, call: _) =
    openai.with_http_timeout(original, 5_000)
  let assert True =
    updated.api_key == "sk-test"
    && updated.model == "gpt-4o"
    && updated.base_url == "http://localhost:11434/v1"
    && updated.http_timeout_ms == 5_000
}
