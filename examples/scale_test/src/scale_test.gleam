//// Scale Test — Digital Organism Ecosystem
//// Main entry point: Mist HTTP + WebSocket server

import gleam/bytes_tree
import gleam/erlang/application
import gleam/erlang/process.{type Selector, type Subject, subject_owner}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import group_registry.{type GroupRegistry}
import lustre
import lustre/attribute
import lustre/element
import lustre/element/html
import lustre/server_component
import mist.{type Connection, type ResponseData}
import scale_test/world.{type WorldMsg, type WorldSnapshot}
import scale_test/ecosystem as ecosystem

// MAIN ------------------------------------------------------------------------

pub fn main() {
  // Start the group registry for pub/sub between world and Lustre runtimes.
  // The registry carries WorldSnapshot messages.
  let name = process.new_name("ecosystem-registry")
  let assert Ok(actor.Started(data: registry, ..)) = group_registry.start(name)

  // Start the world actor. It receives the registry so it can broadcast
  // snapshots to connected clients after each simulation tick.
  let assert Ok(actor.Started(data: world, ..)) =
    world.start(registry)

  let assert Ok(_) =
    fn(request: Request(Connection)) -> Response(ResponseData) {
      case request.path_segments(request) {
        [] -> serve_html()
        ["lustre", "runtime.mjs"] -> serve_runtime()
        ["ws"] -> serve_ecosystem(request, registry, world)
        _ ->
          response.set_body(response.new(404), mist.Bytes(bytes_tree.new()))
      }
    }
    |> mist.new
    |> mist.bind("localhost")
    |> mist.port(3000)
    |> mist.start

  process.sleep_forever()
}

// HTML ------------------------------------------------------------------------

fn serve_html() -> Response(ResponseData) {
  let doc =
    html.html([attribute.lang("en")], [
      html.head([], [
        html.meta([attribute.charset("utf-8")]),
        html.meta([
          attribute.name("viewport"),
          attribute.content("width=device-width, initial-scale=1"),
        ]),
        html.title([], "Scale Test — Digital Organism Ecosystem"),
        html.script(
          [attribute.type_("module"), attribute.src("/lustre/runtime.mjs")],
          "",
        ),
      ]),
      html.body([attribute.style("margin", "0")], [
        server_component.element([server_component.route("/ws")], []),
      ]),
    ])
    |> element.to_document_string_tree
    |> bytes_tree.from_string_tree

  response.new(200)
  |> response.set_body(mist.Bytes(doc))
  |> response.set_header("content-type", "text/html")
}

// JAVASCRIPT RUNTIME ----------------------------------------------------------

fn serve_runtime() -> Response(ResponseData) {
  let assert Ok(lustre_priv) = application.priv_directory("lustre")
  let file_path = lustre_priv <> "/static/lustre-server-component.min.mjs"

  case mist.send_file(file_path, offset: 0, limit: None) {
    Ok(file) ->
      response.new(200)
      |> response.prepend_header("content-type", "application/javascript")
      |> response.set_body(file)

    Error(_) ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

// WEBSOCKET -------------------------------------------------------------------

fn serve_ecosystem(
  request: Request(Connection),
  registry: GroupRegistry(WorldSnapshot),
  world: Subject(WorldMsg),
) -> Response(ResponseData) {
  mist.websocket(
    request:,
    on_init: init_socket(_, registry, world),
    handler: loop_socket,
    on_close: close_socket,
  )
}

type SocketState {
  SocketState(
    component: lustre.Runtime(ecosystem.Message),
    self: Subject(server_component.ClientMessage(ecosystem.Message)),
    registry: GroupRegistry(WorldSnapshot),
  )
}

type SocketMessage =
  server_component.ClientMessage(ecosystem.Message)

fn init_socket(
  _conn: mist.WebsocketConnection,
  registry: GroupRegistry(WorldSnapshot),
  world: Subject(WorldMsg),
) -> #(SocketState, Option(Selector(SocketMessage))) {
  let env = ecosystem.Env(registry:, world:)
  let eco = ecosystem.component()
  let assert Ok(component) = lustre.start_server_component(eco, env)

  let self = process.new_subject()
  let selector = process.new_selector() |> process.select(self)

  server_component.register_subject(self)
  |> lustre.send(to: component)

  #(
    SocketState(component:, self:, registry:),
    Some(selector),
  )
}

fn loop_socket(
  state: SocketState,
  message: mist.WebsocketMessage(SocketMessage),
  connection: mist.WebsocketConnection,
) -> mist.Next(SocketState, SocketMessage) {
  case message {
    mist.Text(json_string) -> {
      case json.parse(json_string, server_component.runtime_message_decoder()) {
        Ok(runtime_message) -> lustre.send(state.component, runtime_message)
        Error(_) -> Nil
      }
      mist.continue(state)
    }
    mist.Binary(_) -> mist.continue(state)
    mist.Custom(client_message) -> {
      let encoded =
        server_component.client_message_to_json(client_message)
      // Gracefully handle send failure (e.g. connection already closed)
      // instead of crashing with let assert.
      case mist.send_text_frame(connection, json.to_string(encoded)) {
        Ok(_) -> Nil
        Error(_) -> Nil
      }
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn close_socket(state: SocketState) -> Nil {
  // Leave the group registry to prevent stale member entries.
  case subject_owner(state.self) {
    Ok(pid) -> group_registry.leave(state.registry, "ecosystem", [pid])
    Error(Nil) -> Nil
  }
  // Shut down the Lustre component runtime to avoid a zombie process.
  lustre.shutdown()
  |> lustre.send(to: state.component)
}
