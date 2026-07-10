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
