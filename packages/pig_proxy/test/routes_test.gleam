import gleam/list
import gleeunit
import pig_otel
import pig_proxy/config
import pig_proxy/routes

pub fn main() -> Nil {
  gleeunit.main()
}

fn target(id: String) -> config.UpstreamTarget {
  config.openai_target(id, "https://example.test/v1", "key")
}

fn check_resolve(
  cfg: config.ProxyConfig,
  api: pig_otel.Api,
  model: String,
) -> List(config.UpstreamTarget) {
  routes.resolve_request(cfg, api, model)
}

fn check_validate(
  cfg: config.ProxyConfig,
) -> Result(Nil, routes.ValidationError) {
  routes.validate(cfg)
}

pub fn strict_route_matrix_is_exact_and_fail_closed_test() {
  let cfg =
    config.new([
      target("chat"),
      config.codex_target("codex", "https://codex.test"),
    ])
    |> config.with_routes([
      config.model_route(pig_otel.ChatCompletions, "gpt-chat", "chat"),
      config.model_route(pig_otel.ChatCompletions, "unknown", "chat"),
      config.model_route(pig_otel.Responses, "gpt-codex", "codex"),
    ])
  let cases = [
    #(pig_otel.ChatCompletions, "gpt-chat", ["chat"]),
    #(pig_otel.ChatCompletions, "unknown", ["chat"]),
    #(pig_otel.Responses, "gpt-codex", ["codex"]),
    #(pig_otel.Responses, "gpt-chat", []),
    #(pig_otel.ChatCompletions, "gpt-codex", []),
    #(pig_otel.Responses, "unknown", []),
    #(pig_otel.ChatCompletions, "unregistered", []),
  ]
  list.each(cases, fn(scenario) {
    let #(api, model, expected_ids) = scenario
    let ids = check_resolve(cfg, api, model) |> list.map(fn(t) { t.id })
    assert expected_ids == ids
  })
  assert Ok(Nil) == check_validate(cfg)
}

pub fn default_multi_is_fail_closed_at_request_time_test() {
  let cfg = config.new([target("one"), target("two")])
  assert [] == check_resolve(cfg, pig_otel.ChatCompletions, "any-model")
  assert Error(routes.MultipleDefaultTargets) == check_validate(cfg)
}

pub fn default_single_target_preserves_default_behavior_test() {
  let cfg = config.new([target("only")])
  assert ["only"]
    == check_resolve(cfg, pig_otel.ChatCompletions, "any-model")
    |> list.map(fn(t) { t.id })
  assert ["only"]
    == check_resolve(cfg, pig_otel.Responses, "any-model")
    |> list.map(fn(t) { t.id })
}

pub fn invalid_configuration_matrix_is_rejected_test() {
  let default_multi = config.new([target("one"), target("two")])
  let duplicate_ids = config.new([target("same"), target("same")])
  let duplicate_routes =
    config.new([target("one")])
    |> config.with_routes([
      config.model_route(pig_otel.ChatCompletions, "model", "one"),
      config.model_route(pig_otel.ChatCompletions, "model", "one"),
    ])
  let missing_target =
    config.new([target("one")])
    |> config.with_routes([
      config.model_route(pig_otel.ChatCompletions, "model", "missing"),
    ])
  let incompatible =
    config.new([config.codex_target("codex", "https://codex.test")])
    |> config.with_routes([
      config.model_route(pig_otel.ChatCompletions, "model", "codex"),
    ])
  let empty_model =
    config.new([target("one")])
    |> config.with_routes([
      config.model_route(pig_otel.ChatCompletions, " \t ", "one"),
    ])
  let empty_target_id = config.new([target(" \t ")])
  let empty_route_target =
    config.new([target("one")])
    |> config.with_routes([
      config.model_route(pig_otel.Responses, "model", "  "),
    ])
  let cases = [
    #(default_multi, routes.MultipleDefaultTargets),
    #(duplicate_ids, routes.DuplicateTargetId("same")),
    #(
      duplicate_routes,
      routes.DuplicateRoute(pig_otel.ChatCompletions, "model"),
    ),
    #(missing_target, routes.MissingTarget("missing")),
    #(
      incompatible,
      routes.IncompatibleTargetApi("codex", pig_otel.ChatCompletions),
    ),
    #(empty_model, routes.EmptyModel),
    #(empty_target_id, routes.EmptyTargetId),
    #(empty_route_target, routes.EmptyRouteTargetId),
  ]
  list.each(cases, fn(scenario) {
    let #(cfg, expected_error) = scenario
    assert Error(expected_error) == check_validate(cfg)
  })
}

pub fn empty_strict_routes_are_typed_configuration_error_test() {
  let cfg = config.new([target("one")]) |> config.with_routes([])
  assert Error(routes.EmptyStrictRoutes) == check_validate(cfg)
  assert "strict routing requires at least one model route"
    == routes.describe(routes.EmptyStrictRoutes)
}

pub fn strict_resolution_checks_api_support_without_startup_validation_test() {
  let cfg =
    config.new([
      config.with_api(target("chat-only"), pig_otel.ChatCompletions),
    ])
    |> config.with_routes([
      config.model_route(pig_otel.Responses, "bad-route", "chat-only"),
    ])
  assert [] == check_resolve(cfg, pig_otel.Responses, "bad-route")
}

pub fn strict_route_never_uses_another_configured_target_test() {
  let cfg =
    config.new([target("first"), target("second")])
    |> config.with_routes([
      config.model_route(pig_otel.Responses, "known", "second"),
    ])
  assert [] == check_resolve(cfg, pig_otel.ChatCompletions, "unknown")
  assert [] == check_resolve(cfg, pig_otel.Responses, "unknown")
}
