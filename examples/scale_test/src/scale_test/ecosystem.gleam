//// Lustre server component for the ecosystem SVG visualization.
//// Renders a grid of organisms and controls panel.

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import group_registry.{type GroupRegistry}
import lustre
import lustre/attribute.{attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import lustre/server_component
import scale_test/world.{
  type WorldMsg, type WorldSnapshot, WorldSnapshot, Stats, TogglePause,
  Reset as WorldReset, SetLLMConcurrency,
}

// ENV --------------------------------------------------------------------------

/// Environment passed to the component when started.
pub type Env {
  Env(registry: GroupRegistry(WorldSnapshot), world: Subject(WorldMsg))
}

// COMPONENT -------------------------------------------------------------------

pub fn component() -> lustre.App(Env, Model, Message) {
  lustre.application(init, update, view)
}

// MODEL -----------------------------------------------------------------------

pub type Model {
  Model(
    organisms: WorldSnapshot,
    registry: GroupRegistry(WorldSnapshot),
    world: Subject(WorldMsg),
  )
}

fn init(env: Env) -> #(Model, Effect(Message)) {
  let model = Model(
    organisms: WorldSnapshot(
      plants: [],
      herbivores: [],
      predators: [],
      stats: Stats(
        tick: 0, plants: 0, herbivores: 0, predators: 0, births: 0, deaths: 0,
      ),
      paused: False,
      tick_speed: 200,
      llm_calls: 0,
      llm_errors: 0,
      llm_queue: 0,
      llm_in_flight: 0,
      llm_max_concurrency: 8,
      llm_model: "",
    ),
    registry: env.registry,
    world: env.world,
  )
  // Subscribe directly via world actor
  let sub = process.new_subject()
  let _ = process.send(env.world, world.Subscribe(sub))
  #(model, subscribe_direct(sub))
}

fn subscribe_direct(subject: Subject(WorldSnapshot)) -> Effect(Message) {
  use _, _ <- server_component.select
  let selector =
    process.new_selector()
    |> process.select_map(subject, SnapshotReceived)
  selector
}

// MESSAGES --------------------------------------------------------------------

pub opaque type Message {
  SnapshotReceived(WorldSnapshot)
  UserClickedPause
  UserClickedReset
  UserChangedLLMConcurrency(concurrency: Int)
}

// UPDATE ----------------------------------------------------------------------

fn update(model: Model, msg: Message) -> #(Model, Effect(Message)) {
  case msg {
    SnapshotReceived(snapshot) -> {
      #(Model(..model, organisms: snapshot), effect.none())
    }
    UserClickedPause -> {
      #(model, send_to_world(model.world, TogglePause))
    }
    UserClickedReset -> {
      #(model, send_to_world(model.world, WorldReset(300, 20, 10)))
    }
    UserChangedLLMConcurrency(concurrency) -> {
      #(model, send_to_world(model.world, SetLLMConcurrency(concurrency)))
    }
  }
}

fn send_to_world(world: Subject(WorldMsg), msg: WorldMsg) -> Effect(Message) {
  effect.from(fn(_) { process.send(world, msg) })
}

// VIEW ------------------------------------------------------------------------

fn view(model: Model) -> Element(Message) {
  element.fragment([
    html.style([], css()),
    html.div([attribute.id("app")], [
      render_stats(model.organisms),
      render_controls(model.organisms),
      render_grid(model.organisms),
    ]),
  ])
}

fn render_stats(snapshot: WorldSnapshot) -> Element(Message) {
  let s = snapshot.stats
  html.div([attribute.id("stats")], [
    html.div([], [
      html.text("Tick: " <> int.to_string(s.tick) <> "  |  "),
      html.text("\u{1F33F} "),
      html.span([attribute.style("color", "#22c55e")], [
        html.text(int.to_string(s.plants)),
      ]),
      html.text("  "),
      html.text("\u{1F430} "),
      html.span([attribute.style("color", "#3b82f6")], [
        html.text(int.to_string(s.herbivores)),
      ]),
      html.text("  "),
      html.text("\u{1F43A} "),
      html.span([attribute.style("color", "#ef4444")], [
        html.text(int.to_string(s.predators)),
      ]),
      html.text("  |  Births: " <> int.to_string(s.births) <> "  Deaths: " <> int.to_string(s.deaths)),
    ]),
    html.div([attribute.style("margin-top", "0.25rem")], [
      html.text(
        "\u{1F9E0} " <> snapshot.llm_model <> "  |  "
        <> "Calls: " <> int.to_string(snapshot.llm_calls) <> "  "
        <> "Errors: " <> int.to_string(snapshot.llm_errors) <> "  |  "
        <> "Queue: " <> int.to_string(snapshot.llm_queue) <> "  "
        <> "In-flight: "
        <> int.to_string(snapshot.llm_in_flight)
        <> "/"
        <> int.to_string(snapshot.llm_max_concurrency),
      ),
    ]),
  ])
}

fn render_controls(snapshot: WorldSnapshot) -> Element(Message) {
  let pause_label = case snapshot.paused {
    True -> "\u{25B6} Resume"
    False -> "\u{23F8} Pause"
  }
  html.div([attribute.id("controls")], [
    html.button([event.on_click(UserClickedPause)], [
      html.text(pause_label),
    ]),
    html.button([event.on_click(UserClickedReset)], [
      html.text("\u{1F504} Reset"),
    ]),
    html.label([], [
      html.text("\u{1F9E0} LLM: "),
      html.input([
        attribute.type_("range"),
        attribute.min("0"),
        attribute.max("20"),
        attribute.value(int.to_string(snapshot.llm_max_concurrency)),
        event.on(
          "change",
          decode.field("target", decode.dynamic, fn(_target) {
            decode.field("value", decode.string, fn(value) {
              case int.parse(value) {
                Ok(n) -> decode.success(UserChangedLLMConcurrency(n))
                Error(_) -> decode.success(UserChangedLLMConcurrency(3))
              }
            })
          }),
        )
        |> server_component.include(["target.value"]),
      ]),
    ]),
  ])
}

fn render_grid(snapshot: WorldSnapshot) -> Element(Message) {
  let cell_size = 8
  let view_size = 50 * cell_size

  let plant_cells =
    list.map(snapshot.plants, fn(pos_energy) {
      let #(pos, energy) = pos_energy
      let #(x, y) = pos
      let opacity = int.min(100, energy * 5) |> int.to_string
      svg.rect([
        attribute("x", int.to_string(x * cell_size)),
        attribute("y", int.to_string(y * cell_size)),
        attribute("width", int.to_string(cell_size)),
        attribute("height", int.to_string(cell_size)),
        attribute("fill", "#22c55e"),
        attribute("opacity", opacity <> "%"),
      ])
    })

  let herb_cells =
    list.map(snapshot.herbivores, fn(pos_energy) {
      let #(pos, energy) = pos_energy
      let #(x, y) = pos
      let opacity = int.min(100, energy * 4) |> int.to_string
      svg.rect([
        attribute("x", int.to_string(x * cell_size)),
        attribute("y", int.to_string(y * cell_size)),
        attribute("width", int.to_string(cell_size)),
        attribute("height", int.to_string(cell_size)),
        attribute("fill", "#3b82f6"),
        attribute("opacity", opacity <> "%"),
      ])
    })

  let pred_cells =
    list.map(snapshot.predators, fn(pos_energy) {
      let #(pos, energy) = pos_energy
      let #(x, y) = pos
      let opacity = int.min(100, energy * 4) |> int.to_string
      svg.rect([
        attribute("x", int.to_string(x * cell_size)),
        attribute("y", int.to_string(y * cell_size)),
        attribute("width", int.to_string(cell_size)),
        attribute("height", int.to_string(cell_size)),
        attribute("fill", "#ef4444"),
        attribute("opacity", opacity <> "%"),
      ])
    })

  let all_cells =
    list.append(list.append(plant_cells, herb_cells), pred_cells)

  html.svg(
    [
      attribute(
        "viewBox",
        "0 0 "
        <> int.to_string(view_size)
        <> " "
        <> int.to_string(view_size),
      ),
      attribute("width", "100%"),
      attribute("height", "100%"),
      attribute("xmlns", "http://www.w3.org/2000/svg"),
      attribute("style", "background: #111827; border-radius: 8px;"),
    ],
    all_cells,
  )
}

fn css() -> String {
  "
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: system-ui, -apple-system, sans-serif;
    background: #0f172a;
    color: #e2e8f0;
    min-height: 100vh;
  }
  #app {
    display: flex;
    flex-direction: column;
    align-items: center;
    padding: 1rem;
    gap: 0.5rem;
  }
  #stats {
    font-size: 0.9rem;
    color: #94a3b8;
    padding: 0.5rem 1rem;
    background: #1e293b;
    border-radius: 0.5rem;
  }
  #controls {
    display: flex;
    gap: 0.75rem;
    align-items: center;
    padding: 0.5rem 1rem;
    background: #1e293b;
    border-radius: 0.5rem;
  }
  button {
    padding: 0.4rem 0.8rem;
    border: 1px solid #475569;
    border-radius: 0.375rem;
    background: #334155;
    color: #e2e8f0;
    cursor: pointer;
    font-size: 0.85rem;
  }
  button:hover { background: #475569; }
  label { font-size: 0.85rem; color: #94a3b8; }
  input[type=range] { width: 120px; }
  svg { max-width: 800px; }
  "
}
