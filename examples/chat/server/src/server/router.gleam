import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/string_tree

import lustre_pipes/attribute
import lustre_pipes/element.{children, empty, text_content}
import lustre_pipes/element/html

import filepath
import lustre/server_component
import mist
import wisp.{type Request, type Response}
import wisp/wisp_mist

import omnimessage/server as omniserver

import server/components/chat
import server/context.{type Context}

fn cors_middleware(req: Request, fun: fn() -> Response) -> Response {
  case req.method {
    http.Options -> {
      wisp.response(200)
      |> wisp.set_header("access-control-allow-origin", "*")
      |> wisp.set_header("access-control-allow-methods", "GET, POST, OPTIONS")
      |> wisp.set_header(
        "access-control-allow-headers",
        "Content-Type,Content-Encoding",
      )
    }
    _ -> {
      fun()
      |> wisp.set_header("access-control-allow-origin", "*")
      |> wisp.set_header("access-control-allow-methods", "GET, POST, OPTIONS")
      |> wisp.set_header(
        "access-control-allow-headers",
        "Content-Type,Content-Encoding",
      )
    }
  }
}

fn static_middleware(req: Request, fun: fn() -> Response) -> Response {
  let assert Ok(priv) = wisp.priv_directory("server")
  let priv_static = filepath.join(priv, "static")
  wisp.serve_static(req, under: "/priv/static", from: priv_static, next: fun)
}

fn wisp_handler(req, _ctx) {
  use <- cors_middleware(req)
  use <- static_middleware(req)

  case wisp.path_segments(req), req.method {
    [], http.Get -> home()
    _, _ -> wisp.not_found()
  }
}

pub fn mist_handler(
  req: request.Request(mist.Connection),
  ctx: Context,
  secret_key_base,
) -> response.Response(mist.ResponseData) {
  let wisp_mist_handler =
    fn(req) { wisp_handler(req, ctx) }
    |> wisp_mist.handler(secret_key_base)

  case request.path_segments(req), req.method {
    ["omni-app-ws"], http.Get ->
      omniserver.mist_websocket_application(req, chat.app(), ctx, fn(_) { Nil })
    _, _ -> wisp_mist_handler(req)
  }
}

fn page_scaffold(
  content: element.Element(a),
  init_json: String,
) -> element.Element(a) {
  html.html()
  |> attribute.attribute("lang", "en")
  |> attribute.class("h-full w-full overflow-hidden")
  |> children([
    html.head()
      |> children([
        html.meta()
          |> attribute.attribute("charset", "UTF-8")
          |> empty(),
        html.meta()
          |> attribute.name("viewport")
          |> attribute.attribute(
            "content",
            "width=device-width, initial-scale=1.0",
          )
          |> empty(),
        html.title()
          |> text_content("Pig Chat"),
        html.script()
          |> attribute.src("https://cdn.tailwindcss.com")
          |> empty(),
        html.script()
          |> attribute.src("/priv/static/client.mjs")
          |> attribute.type_("module")
          |> empty(),
        server_component.script(),
        html.script()
          |> attribute.id("model")
          |> attribute.type_("module")
          |> text_content(init_json),
      ]),
    html.body()
      |> attribute.class("h-full w-full")
      |> children([
        html.div()
        |> attribute.id("app")
        |> attribute.class("h-full w-full")
        |> children([content]),
      ]),
  ])
}

fn home() -> Response {
  wisp.response(200)
  |> wisp.set_header("Content-Type", "text/html")
  |> wisp.html_body(
    html.div()
    |> empty()
    |> page_scaffold("")
    |> element.to_document_string_tree()
    |> string_tree.replace("\\n", "")
    |> string_tree.to_string(),
  )
}
