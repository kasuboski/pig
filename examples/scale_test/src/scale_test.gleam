//// Scale Test — Digital Organism Ecosystem
//// Main entry point: Mist HTTP + WebSocket server

import envoy
import gleam/bytes_tree
import gleam/erlang/application
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import lustre
import lustre/attribute
import lustre/element
import lustre/element/html
import lustre/server_component
import mist.{type Connection, type ResponseData}
import scale_test/ecosystem
import scale_test/scheduler
import scale_test/world.{type WorldMsg, SetScheduler}

// MAIN ------------------------------------------------------------------------

pub fn main() {
  // Read config from env vars
  let base_url =
    result.unwrap(
      envoy.get("OPENAI_COMPAT_BASE_URL"),
      "http://localhost:11434/v1",
    )
  let api_key = result.unwrap(envoy.get("OPENAI_COMPAT_API_KEY"), "ollama")
  let model = result.unwrap(envoy.get("OPENAI_COMPAT_MODEL"), "gemopuse4b")

  // Start the world actor.
  let assert Ok(actor.Started(data: world, ..)) = world.start()

  // Start the scheduler for LLM-driven decisions.
  let assert Ok(actor.Started(data: scheduler_subject, ..)) =
    scheduler.start(8, world: world, base_url:, api_key:, model:)

  // Wire scheduler to world:
  // - World gets the scheduler subject to send re-think requests
  // - Scheduler gets the world subject directly (no forwarder needed)
  process.send(world, SetScheduler(scheduler_subject, model_name: model))

  let assert Ok(_) =
    fn(request: Request(Connection)) -> Response(ResponseData) {
      case request.path_segments(request) {
        [] -> serve_html()
        ["lustre", "runtime.mjs"] -> serve_runtime()
        ["ws"] -> serve_ecosystem(request, world)
        _ -> response.set_body(response.new(404), mist.Bytes(bytes_tree.new()))
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
  world: Subject(WorldMsg),
) -> Response(ResponseData) {
  mist.websocket(
    request:,
    on_init: init_socket(_, world),
    handler: loop_socket,
    on_close: close_socket,
  )
}

type SocketState {
  SocketState(
    component: lustre.Runtime(ecosystem.Message),
    self: Subject(server_component.ClientMessage(ecosystem.Message)),
  )
}

type SocketMessage {
  ClientMsg(server_component.ClientMessage(ecosystem.Message))
  SnapshotMsg(world.WorldSnapshot)
}

fn init_socket(
  _conn: mist.WebsocketConnection,
  world: Subject(WorldMsg),
) -> #(SocketState, Option(Selector(SocketMessage))) {
  let env = ecosystem.Env(world:)
  let eco = ecosystem.component()
  let assert Ok(component) = lustre.start_server_component(eco, env)

  let self = process.new_subject()
  // Subscribe to world snapshots directly
  let snapshot_sub = process.new_subject()
  process.send(world, world.Subscribe(snapshot_sub))

  let selector =
    process.new_selector()
    |> process.select_map(self, ClientMsg)
    |> process.select_map(snapshot_sub, SnapshotMsg)

  server_component.register_subject(self)
  |> lustre.send(to: component)

  #(SocketState(component:, self:), Some(selector))
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
      case client_message {
        ClientMsg(msg) -> {
          let encoded = server_component.client_message_to_json(msg)
          case mist.send_text_frame(connection, json.to_string(encoded)) {
            Ok(_) -> Nil
            Error(_) -> Nil
          }
        }
        SnapshotMsg(snapshot) -> {
          // Forward snapshot to Lustre component as a runtime message
          lustre.send(
            state.component,
            lustre.dispatch(ecosystem.SnapshotReceived(snapshot)),
          )
        }
      }
      mist.continue(state)
    }
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn close_socket(state: SocketState) -> Nil {
  lustre.shutdown()
  |> lustre.send(to: state.component)
}
