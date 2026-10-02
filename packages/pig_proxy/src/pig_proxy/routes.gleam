//// Pure validation and resolution for API/model routing.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import pig_otel
import pig_proxy/config as proxy_config

/// Configuration problems that prevent safe request routing.
pub type ValidationError {
  MultipleDefaultTargets
  EmptyStrictRoutes
  EmptyTargetId
  DuplicateTargetId(String)
  EmptyModel
  DuplicateRoute(pig_otel.Api, String)
  EmptyRouteTargetId
  MissingTarget(String)
  IncompatibleTargetApi(String, pig_otel.Api)
}

/// Describe a routing validation failure without exposing target credentials.
pub fn describe(error: ValidationError) -> String {
  case error {
    MultipleDefaultTargets -> "default routing requires exactly one target"
    EmptyStrictRoutes -> "strict routing requires at least one model route"
    EmptyTargetId -> "target id must not be blank"
    DuplicateTargetId(id) -> "duplicate target id: " <> id
    EmptyModel -> "route model must not be blank"
    DuplicateRoute(_, model) -> "duplicate API/model route for model: " <> model
    EmptyRouteTargetId -> "route target id must not be blank"
    MissingTarget(id) -> "route references missing target: " <> id
    IncompatibleTargetApi(id, _) ->
      "target does not support the route API: " <> id
  }
}

/// Validate all routing data before the server accepts requests.
pub fn validate(cfg: proxy_config.ProxyConfig) -> Result(Nil, ValidationError) {
  use _ <- result.try(validate_targets(cfg.targets, []))
  case cfg.routing {
    proxy_config.DefaultTarget ->
      case cfg.targets {
        [_, _, ..] -> Error(MultipleDefaultTargets)
        _ -> Ok(Nil)
      }
    proxy_config.StrictRoutes(model_routes) ->
      case model_routes {
        [] -> Error(EmptyStrictRoutes)
        _ -> validate_routes(cfg, model_routes, [])
      }
  }
}

/// Make the real routing decision for an incoming API and model.
/// Strict routes fail closed: unknown models and API mismatches produce no targets.
pub fn resolve_request(
  cfg: proxy_config.ProxyConfig,
  api: pig_otel.Api,
  model: String,
) -> List(proxy_config.UpstreamTarget) {
  case cfg.routing {
    proxy_config.DefaultTarget ->
      case cfg.targets {
        [target] ->
          case supports(target.api_support, api) {
            True -> [target]
            False -> []
          }
        _ -> []
      }
    proxy_config.StrictRoutes(model_routes) -> {
      let matching =
        list.find(model_routes, fn(route) {
          route.api == api && route.model == model
        })
      case matching {
        Ok(route) ->
          case proxy_config.find_target(cfg, route.target_id) {
            Some(target) ->
              case supports(target.api_support, api) {
                True -> [target]
                False -> []
              }
            None -> []
          }
        Error(_) -> []
      }
    }
  }
}

fn validate_targets(
  targets: List(proxy_config.UpstreamTarget),
  seen: List(String),
) -> Result(Nil, ValidationError) {
  case targets {
    [] -> Ok(Nil)
    [target, ..rest] -> {
      use _ <- result.try(case blank(target.id) {
        True -> Error(EmptyTargetId)
        False ->
          case list.contains(seen, target.id) {
            True -> Error(DuplicateTargetId(target.id))
            False -> Ok(Nil)
          }
      })
      validate_targets(rest, [target.id, ..seen])
    }
  }
}

fn validate_routes(
  cfg: proxy_config.ProxyConfig,
  model_routes: List(proxy_config.ModelRoute),
  seen: List(#(pig_otel.Api, String)),
) -> Result(Nil, ValidationError) {
  case model_routes {
    [] -> Ok(Nil)
    [route, ..rest] -> {
      use _ <- result.try(case blank(route.model) {
        True -> Error(EmptyModel)
        False ->
          case blank(route.target_id) {
            True -> Error(EmptyRouteTargetId)
            False ->
              case list.contains(seen, #(route.api, route.model)) {
                True -> Error(DuplicateRoute(route.api, route.model))
                False -> Ok(Nil)
              }
          }
      })
      use target <- result.try(
        case proxy_config.find_target(cfg, route.target_id) {
          Some(target) -> Ok(target)
          None -> Error(MissingTarget(route.target_id))
        },
      )
      use _ <- result.try(case supports(target.api_support, route.api) {
        True -> Ok(Nil)
        False -> Error(IncompatibleTargetApi(target.id, route.api))
      })
      validate_routes(cfg, rest, [#(route.api, route.model), ..seen])
    }
  }
}

fn blank(value: String) -> Bool {
  string.trim(value) == ""
}

fn supports(support: proxy_config.ApiSupport, api: pig_otel.Api) -> Bool {
  case support {
    proxy_config.BothApis -> True
    proxy_config.OnlyApi(allowed) -> allowed == api
  }
}
