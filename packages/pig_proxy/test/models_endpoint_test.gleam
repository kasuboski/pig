import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit
import pig_otel
import pig_proxy/config
import pig_proxy/models_endpoint

pub fn main() -> Nil {
  gleeunit.main()
}

type ListedModel {
  ListedModel(id: String, object: String, created: Int, owned_by: String)
}

fn target(id: String) -> config.UpstreamTarget {
  config.openai_target(id, "https://upstream.example/v1", "secret-key")
}

fn check_models(config: config.ProxyConfig) -> List(ListedModel) {
  let assert Ok(#("list", models)) =
    json.parse(models_endpoint.render(config), decode_model_list())
  models
}

fn decode_model_list() -> decode.Decoder(#(String, List(ListedModel))) {
  use object <- decode.field("object", decode.string)
  use data <- decode.field("data", decode.list(decode_model()))
  decode.success(#(object, data))
}

fn decode_model() -> decode.Decoder(ListedModel) {
  use id <- decode.field("id", decode.string)
  use object <- decode.field("object", decode.string)
  use created <- decode.field("created", decode.int)
  use owned_by <- decode.field("owned_by", decode.string)
  decode.success(ListedModel(id:, object:, created:, owned_by:))
}

fn check_model_fields(
  models: List(ListedModel),
  expected: List(#(String, String)),
) -> Nil {
  assert list.map(models, fn(model) { model.id })
    == list.map(expected, fn(entry) { entry.0 })
  list.each(list.zip(models, expected), fn(pair) {
    let #(model, #(id, owner)) = pair
    assert model.id == id
    assert model.object == "model"
    assert model.created == 0
    assert model.owned_by == owner
  })
}

pub fn advertises_all_explicit_user_models_in_route_order_test() {
  let cfg =
    config.new([
      config.with_provider(
        config.codex_target("openai", "https://codex.example"),
        "openai",
      ),
      target("zai")
        |> config.with_api(pig_otel.ChatCompletions)
        |> config.with_provider("zai"),
    ])
    |> config.with_routes([
      config.model_route(pig_otel.Responses, "gpt-6-astra", "openai"),
      config.model_route(pig_otel.Responses, "gpt-6-sol", "openai"),
      config.model_route(pig_otel.Responses, "gpt-6-luna", "openai"),
      config.model_route(pig_otel.Responses, "gpt-6.1-sol", "openai"),
      config.model_route(pig_otel.ChatCompletions, "glm-5.3", "zai"),
      config.model_route(pig_otel.ChatCompletions, "glm-5.3-flash", "zai"),
    ])
  check_model_fields(check_models(cfg), [
    #("gpt-6-astra", "openai"),
    #("gpt-6-sol", "openai"),
    #("gpt-6-luna", "openai"),
    #("gpt-6.1-sol", "openai"),
    #("glm-5.3", "zai"),
    #("glm-5.3-flash", "zai"),
  ])
}

pub fn deduplicates_model_ids_across_supported_apis_test() {
  let cfg =
    config.new([
      config.with_provider(target("openai"), "openai"),
      config.with_provider(target("zai"), "zai"),
    ])
    |> config.with_routes([
      config.model_route(pig_otel.ChatCompletions, "shared", "zai"),
      config.model_route(pig_otel.Responses, "shared", "openai"),
      config.model_route(pig_otel.Responses, "later", "openai"),
    ])
  check_model_fields(check_models(cfg), [
    #("shared", "zai"),
    #("later", "openai"),
  ])
}

pub fn blank_or_unknown_provider_uses_proxy_owner_test() {
  let cfg =
    config.new([
      config.with_provider(target("blank"), " \t "),
      target("unknown"),
    ])
    |> config.with_routes([
      config.model_route(pig_otel.ChatCompletions, "blank-owner", "blank"),
      config.model_route(pig_otel.Responses, "unknown-owner", "unknown"),
    ])
  check_model_fields(check_models(cfg), [
    #("blank-owner", "pig_proxy"),
    #("unknown-owner", "pig_proxy"),
  ])
}

pub fn default_and_empty_strict_configs_advertise_no_models_test() {
  assert [] == check_models(config.new([target("default")]))
  let empty = config.new([target("strict")]) |> config.with_routes([])
  assert [] == check_models(empty)
  assert [] == check_models(config.new([]))
}

pub fn omits_unroutable_unsupported_and_custom_api_routes_test() {
  let cfg =
    config.new([
      config.with_api(target("chat-only"), pig_otel.ChatCompletions),
      target("valid"),
      config.codex_target("responses-only", "https://codex.example/v1"),
    ])
    |> config.with_routes([
      config.model_route(pig_otel.Responses, "incompatible", "chat-only"),
      config.model_route(pig_otel.ChatCompletions, "missing-target", "missing"),
      config.model_route(pig_otel.Custom, "custom-only", "valid"),
      config.model_route(pig_otel.ChatCompletions, " \t ", "valid"),
      config.model_route(
        pig_otel.Responses,
        "valid-responses",
        "responses-only",
      ),
      config.model_route(pig_otel.ChatCompletions, "valid-chat", "valid"),
    ])
  check_model_fields(check_models(cfg), [
    #("valid-responses", "pig_proxy"),
    #("valid-chat", "pig_proxy"),
  ])
}

pub fn escapes_model_ids_and_excludes_credentials_and_urls_test() {
  let model = "quote\" slash\\ newline\n"
  let cfg =
    config.new([
      config.with_provider(
        config.openai_target(
          "private-target",
          "https://private.example/v1",
          "top-secret",
        ),
        "private-provider",
      ),
    ])
    |> config.with_routes([
      config.model_route(pig_otel.ChatCompletions, model, "private-target"),
    ])
  let rendered = models_endpoint.render(cfg)
  let assert [listed] = check_models(cfg)
  assert listed.id == model
  assert string.contains(rendered, "\\\"")
  assert !string.contains(rendered, "top-secret")
  assert !string.contains(rendered, "private-target")
  assert !string.contains(rendered, "private.example")
  assert !string.contains(rendered, "https://")
}
