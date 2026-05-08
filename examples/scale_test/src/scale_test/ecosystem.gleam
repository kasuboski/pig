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
  Reset as WorldReset, SetTickSpeed, TickSpeed,
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
    ),
    registry: env.registry,
    world: env.world,
  )
  #(model, subscribe(env.registry))
}

fn subscribe(registry: GroupRegistry(WorldSnapshot)) -> Effect(Message) {
  use _, _ <- server_component.select
  let subject = group_registry.join(registry, "ecosystem", process.self())
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
  UserChangedTickSpeed(speed: Int)
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
    UserChangedTickSpeed(speed) -> {
      #(model, send_to_world(model.world, SetTickSpeed(TickSpeed(speed))))
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
    html.text(
      "Tick: " <> int.to_string(s.tick) <> "  |  "
      <> "🌿 " <> int.to_string(s.plants) <> "  "
      <> "🐰 " <> int.to_string(s.herbivores) <> "  "
      <> "🐺 " <> int.to_string(s.predators) <> "  |  "
      <> "Births: " <> int.to_string(s.births) <> "  "
      <> "Deaths: " <> int.to_string(s.deaths),
    ),
  ])
}

fn render_controls(snapshot: WorldSnapshot) -> Element(Message) {
  let pause_label = case snapshot.paused {
    True -> "▶ Resume"
    False -> "⏸ Pause"
  }
  html.div([attribute.id("controls")], [
    html.button([event.on_click(UserClickedPause)], [
      html.text(pause_label),
    ]),
    html.button([event.on_click(UserClickedReset)], [
      html.text("🔄 Reset"),
    ]),
    html.label([], [
      html.text("Speed: "),
      html.input([
        attribute.type_("range"),
        attribute.min("50"),
        attribute.max("1000"),
        attribute.value(int.to_string(snapshot.tick_speed)),
        event.on(
          "change",
          decode.field("target", decode.dynamic, fn(_target) {
            decode.field("value", decode.string, fn(value) {
              case int.parse(value) {
                Ok(speed) -> decode.success(UserChangedTickSpeed(speed))
                Error(_) -> decode.success(UserChangedTickSpeed(200))
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
  let view_size = 100 * cell_size

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
