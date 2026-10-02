//// OpenAI-compatible model listing derived only from routable strict routes.

import gleam/bytes_tree
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import mist
import pig_otel
import pig_proxy/config.{type ProxyConfig}
import pig_proxy/routes

/// Render the finite model list advertised by explicit strict routes.
/// IDs keep their first routable occurrence and its provider ownership.
/// Default routing has no explicit inventory and returns an empty list.
pub fn render(config: ProxyConfig) -> String {
  let models = case config.routing {
    config.DefaultTarget -> []
    config.StrictRoutes(model_routes) -> {
      let #(models, _) =
        list.fold(model_routes, #([], []), fn(state, route) {
          let #(models, seen) = state
          let api = case route.api {
            pig_otel.ChatCompletions -> Some(pig_otel.ChatCompletions)
            pig_otel.Responses -> Some(pig_otel.Responses)
            pig_otel.Custom -> None
          }
          case api {
            Some(api) ->
              case
                string.trim(route.model) == ""
                || list.contains(seen, route.model),
                routes.resolve_request(config, api, route.model)
              {
                False, [target, ..] -> {
                  let owner = case target.provider {
                    Some(provider) ->
                      case string.trim(provider) == "" {
                        True -> "pig_proxy"
                        False -> provider
                      }
                    None -> "pig_proxy"
                  }
                  let model =
                    json.object([
                      #("id", json.string(route.model)),
                      #("object", json.string("model")),
                      #("created", json.int(0)),
                      #("owned_by", json.string(owner)),
                    ])
                  #([model, ..models], [route.model, ..seen])
                }
                _, _ -> state
              }
            None -> state
          }
        })
      list.reverse(models)
    }
  }
  json.object([
    #("object", json.string("list")),
    #("data", json.array(from: models, of: fn(model) { model })),
  ])
  |> json.to_string
}

/// Build the HTTP response for `GET /v1/models`.
pub fn response(config: ProxyConfig) -> response.Response(mist.ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(render(config))))
}
