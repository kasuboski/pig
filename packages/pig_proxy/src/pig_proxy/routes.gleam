//// Virtual model routing: maps abstract model slugs (e.g. "smart-model",
//// "fast-model") to ordered fallback chains of upstream targets.
////
//// The router also enforces parameter compatibility — if a request
//// requires tools or strict JSON schema, fallback targets that don't
//// support those capabilities are filtered out.

import gleam/list
import gleam/option.{type Option, None, Some}
import pig_proxy/config.{type ProxyConfig, type UpstreamTarget}

/// A virtual route maps a slug to an ordered list of target ids.
/// The first id is the primary; the rest are fallbacks tried in order
/// when the primary fails or its circuit is open.
pub type VirtualRoute {
  VirtualRoute(slug: String, target_ids: List(String))
}

/// A route resolution result: the ordered list of targets to try.
pub type ResolvedRoute {
  ResolvedRoute(targets: List(UpstreamTarget))
  NoTargets
}

/// Resolve a model slug (which may be a virtual route or a real model
/// name) into an ordered fallback chain of upstream targets.
///
/// If the slug matches a virtual route, the route's target ids are
/// looked up in the config. If no virtual route matches, the slug is
/// treated as a model name and resolved to the default target.
pub fn resolve(
  config: ProxyConfig,
  routes: List(VirtualRoute),
  model_slug: String,
) -> ResolvedRoute {
  case find_route(routes, model_slug) {
    Some(route) -> resolve_target_ids(config, route.target_ids)
    None ->
      // No virtual route — use the first configured target as default.
      case list.first(config.targets) {
        Ok(target) -> ResolvedRoute([target])
        Error(_) -> NoTargets
      }
  }
}

/// Filter a resolved route's targets by capability requirements.
///
/// If the request includes tool definitions, targets with
/// `supports_tools: False` are removed. If the request forces
/// `response_format: json_object`, targets with `supports_json_schema:
/// False` are removed.
pub fn filter_by_capability(
  route: ResolvedRoute,
  requires_tools: Bool,
  requires_json_schema: Bool,
) -> ResolvedRoute {
  case route {
    NoTargets -> NoTargets
    ResolvedRoute(targets) -> {
      let filtered =
        targets
        |> list.filter(fn(t) {
          let tools_ok = !requires_tools || t.supports_tools
          let json_ok = !requires_json_schema || t.supports_json_schema
          tools_ok && json_ok
        })
      case list.is_empty(filtered) {
        True -> NoTargets
        False -> ResolvedRoute(filtered)
      }
    }
  }
}

/// Get the primary target (first in the chain) from a resolved route.
pub fn primary_target(route: ResolvedRoute) -> Option(UpstreamTarget) {
  case route {
    NoTargets -> None
    ResolvedRoute(targets) ->
      case list.first(targets) {
        Ok(target) -> Some(target)
        Error(_) -> None
      }
  }
}

/// Get the fallback targets (all except the first) from a resolved route.
pub fn fallback_targets(route: ResolvedRoute) -> List(UpstreamTarget) {
  case route {
    NoTargets -> []
    ResolvedRoute(targets) -> case targets {
      [] -> []
      [_, ..rest] -> rest
    }
  }
}

/// Create a simple virtual route with a single target.
pub fn route(slug: String, target_id: String) -> VirtualRoute {
  VirtualRoute(slug:, target_ids: [target_id])
}

/// Create a virtual route with a fallback chain.
pub fn route_with_fallbacks(
  slug: String,
  primary_id: String,
  fallback_ids: List(String),
) -> VirtualRoute {
  VirtualRoute(slug:, target_ids: [primary_id, ..fallback_ids])
}

// ── Internal ────────────────────────────────────────────────────

fn find_route(
  routes: List(VirtualRoute),
  slug: String,
) -> Option(VirtualRoute) {
  case list.find(routes, fn(r) { r.slug == slug }) {
    Ok(route) -> Some(route)
    Error(_) -> None
  }
}

fn resolve_target_ids(
  cfg: ProxyConfig,
  ids: List(String),
) -> ResolvedRoute {
  let targets =
    ids
    |> list.filter_map(fn(id) {
      case config.find_target(cfg, id) {
        Some(target) -> Ok(target)
        None -> Error(Nil)
      }
    })
  case list.is_empty(targets) {
    True -> NoTargets
    False -> ResolvedRoute(targets)
  }
}
