import gleam/list
import gleam/option.{None, Some}
import gleeunit
import pig_proxy/config
import pig_proxy/routes

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Test fixtures ───────────────────────────────────────────────

fn test_config() -> config.ProxyConfig {
  config.new([
    config.openai_target("openai", "https://api.openai.com/v1", "sk-key"),
    config.UpstreamTarget(
      id: "ollama",
      base_url: "http://localhost:11434/v1",
      auth: config.ApiKey("ollama"),
      provider: None,
      fallbacks: [],
      supports_tools: True,
      supports_json_schema: False,
    ),
    config.UpstreamTarget(
      id: "simple",
      base_url: "http://localhost:8080/v1",
      auth: config.ApiKey("test"),
      provider: None,
      fallbacks: [],
      supports_tools: False,
      supports_json_schema: False,
    ),
  ])
}

// ── resolve ─────────────────────────────────────────────────────

pub fn resolve_matching_virtual_route_test() {
  let cfg = test_config()
  let rts = [routes.route("smart-model", "openai")]
  let result = routes.resolve(cfg, rts, "smart-model")
  let assert routes.ResolvedRoute(targets) = result
  assert 1 == list.length(targets)
  let assert Some(target) = routes.primary_target(result)
  assert "openai" == target.id
}

pub fn resolve_with_fallback_chain_test() {
  let cfg = test_config()
  let rts = [
    routes.route_with_fallbacks("smart-model", "openai", ["ollama", "simple"]),
  ]
  let result = routes.resolve(cfg, rts, "smart-model")
  let assert routes.ResolvedRoute(targets) = result
  assert 3 == list.length(targets)
  let assert Some(primary) = routes.primary_target(result)
  assert "openai" == primary.id
  let fallbacks = routes.fallback_targets(result)
  assert 2 == list.length(fallbacks)
}

pub fn resolve_no_matching_route_uses_default_test() {
  let cfg = test_config()
  let result = routes.resolve(cfg, [], "gpt-4")
  let assert routes.ResolvedRoute(targets) = result
  assert 1 == list.length(targets)
  let assert Some(target) = routes.primary_target(result)
  assert "openai" == target.id
}

pub fn resolve_no_targets_returns_no_targets_test() {
  let cfg = config.new([])
  let result = routes.resolve(cfg, [], "anything")
  assert routes.NoTargets == result
}

pub fn resolve_route_with_missing_target_filtered_test() {
  let cfg = test_config()
  let rts = [
    routes.route_with_fallbacks("smart-model", "openai", ["nonexistent"]),
  ]
  let result = routes.resolve(cfg, rts, "smart-model")
  let assert routes.ResolvedRoute(targets) = result
  // Only the "openai" target resolves; "nonexistent" is filtered out.
  assert 1 == list.length(targets)
  let assert Some(target) = routes.primary_target(result)
  assert "openai" == target.id
}

pub fn resolve_route_all_targets_missing_returns_no_targets_test() {
  let cfg = test_config()
  let rts = [routes.route("smart-model", "nonexistent")]
  let result = routes.resolve(cfg, rts, "smart-model")
  assert routes.NoTargets == result
}

// ── filter_by_capability ────────────────────────────────────────

pub fn filter_by_capability_no_requirements_passes_all_test() {
  let cfg = test_config()
  let rts = [
    routes.route_with_fallbacks("smart-model", "openai", ["ollama", "simple"]),
  ]
  let route = routes.resolve(cfg, rts, "smart-model")
  let filtered = routes.filter_by_capability(route, False, False)
  let assert routes.ResolvedRoute(targets) = filtered
  assert 3 == list.length(targets)
  let assert Some(primary) = routes.primary_target(filtered)
  assert "openai" == primary.id
}

pub fn filter_by_capability_requires_tools_test() {
  let cfg = test_config()
  let rts = [
    routes.route_with_fallbacks("smart-model", "openai", ["ollama", "simple"]),
  ]
  let route = routes.resolve(cfg, rts, "smart-model")
  let filtered = routes.filter_by_capability(route, True, False)
  let assert routes.ResolvedRoute(targets) = filtered
  // "simple" doesn't support tools → filtered out. "openai" and "ollama" remain.
  assert 2 == list.length(targets)
  let assert Some(primary) = routes.primary_target(filtered)
  assert "openai" == primary.id
  let fallbacks = routes.fallback_targets(filtered)
  assert 1 == list.length(fallbacks)
  let assert [first_fallback] = fallbacks
  assert "ollama" == first_fallback.id
}

pub fn filter_by_capability_requires_json_schema_test() {
  let cfg = test_config()
  let rts = [
    routes.route_with_fallbacks("smart-model", "openai", ["ollama", "simple"]),
  ]
  let route = routes.resolve(cfg, rts, "smart-model")
  let filtered = routes.filter_by_capability(route, False, True)
  let assert routes.ResolvedRoute(targets) = filtered
  // "ollama" and "simple" don't support json_schema → filtered out. Only "openai".
  assert 1 == list.length(targets)
  let assert Some(primary) = routes.primary_target(filtered)
  assert "openai" == primary.id
  assert [] == routes.fallback_targets(filtered)
}

pub fn filter_by_capability_no_targets_returns_no_targets_test() {
  let filtered = routes.filter_by_capability(routes.NoTargets, True, True)
  assert routes.NoTargets == filtered
}

pub fn filter_by_capability_all_filtered_returns_no_targets_test() {
  let cfg = test_config()
  let rts = [routes.route("simple-model", "simple")]
  let route = routes.resolve(cfg, rts, "simple-model")
  let filtered = routes.filter_by_capability(route, True, True)
  assert routes.NoTargets == filtered
}

// ── primary_target / fallback_targets ───────────────────────────

pub fn primary_target_resolved_route_test() {
  let cfg = test_config()
  let rts = [routes.route_with_fallbacks("smart-model", "openai", ["ollama"])]
  let route = routes.resolve(cfg, rts, "smart-model")
  let assert Some(target) = routes.primary_target(route)
  assert "openai" == target.id
}

pub fn primary_target_no_targets_test() {
  assert None == routes.primary_target(routes.NoTargets)
}

pub fn fallback_targets_resolved_route_test() {
  let cfg = test_config()
  let rts = [
    routes.route_with_fallbacks("smart-model", "openai", ["ollama", "simple"]),
  ]
  let route = routes.resolve(cfg, rts, "smart-model")
  let fallbacks = routes.fallback_targets(route)
  assert 2 == list.length(fallbacks)
}

pub fn fallback_targets_no_targets_test() {
  assert [] == routes.fallback_targets(routes.NoTargets)
}

pub fn fallback_targets_single_target_test() {
  let cfg = test_config()
  let rts = [routes.route("smart-model", "openai")]
  let route = routes.resolve(cfg, rts, "smart-model")
  assert [] == routes.fallback_targets(route)
}

// ── builders ────────────────────────────────────────────────────

pub fn route_builder_test() {
  let r = routes.route("fast-model", "ollama")
  assert "fast-model" == r.slug
  assert 1 == list.length(r.target_ids)
}

pub fn route_with_fallbacks_builder_test() {
  let r =
    routes.route_with_fallbacks("smart-model", "openai", ["ollama", "simple"])
  assert "smart-model" == r.slug
  assert 3 == list.length(r.target_ids)
}
