//// Deterministic models.dev-compatible pricing catalog for acceptance tests.

import gleam/json

/// Return prices for the synthetic Responses and Chat Completions models.
pub fn body() -> String {
  let cost =
    json.object([
      #("input", json.int(2)),
      #("output", json.int(10)),
      #("cache_read", json.float(0.5)),
    ])
  let provider = fn(name, model) {
    json.object([
      #("id", json.string(name)),
      #(
        "models",
        json.object([
          #(
            model,
            json.object([
              #("id", json.string(model)),
              #("cost", cost),
            ]),
          ),
        ]),
      ),
    ])
  }
  json.object([
    #("openai", provider("openai", "fake-codex")),
    #("zai", provider("zai", "fake-zai")),
  ])
  |> json.to_string
}
