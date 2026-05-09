//// Lustre server component for the ecosystem SVG visualization.
//// Renders a grid of organisms and controls panel.
//// When simulation ends (all animals dead), shows a statistics overlay.

import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import lustre
import lustre/attribute.{attribute}
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import lustre/server_component
import scale_test/world.{
  type Event, type PopSample, type WorldMsg, type WorldSnapshot, Extinction,
  FirstBirth, FirstDeath, FirstHerbBorn, FirstPredBorn, LastHerbDied,
  LastPredDied, PeakPopulation, Reset as WorldReset, SetLLMConcurrency, Stats,
  TogglePause, WorldSnapshot,
}

// ENV --------------------------------------------------------------------------

/// Environment passed to the component when started.
pub type Env {
  Env(world: Subject(WorldMsg))
}

// COMPONENT -------------------------------------------------------------------

pub fn component() -> lustre.App(Env, Model, Message) {
  lustre.application(init, update, view)
}

// MODEL -----------------------------------------------------------------------

pub type Model {
  Model(organisms: WorldSnapshot, world: Subject(WorldMsg))
}

fn init(env: Env) -> #(Model, Effect(Message)) {
  let model =
    Model(
      organisms: WorldSnapshot(
        plants: [],
        herbivores: [],
        predators: [],
        stats: Stats(
          tick: 0,
          plants: 0,
          herbivores: 0,
          predators: 0,
          births: 0,
          deaths: 0,
        ),
        paused: False,
        tick_speed: 200,
        llm_calls: 0,
        llm_errors: 0,
        llm_queue: 0,
        llm_in_flight: 0,
        llm_max_concurrency: 8,
        llm_model: "",
        finished: False,
        events: [],
        pop_history: [],
        peak_plants: 0,
        peak_herbivores: 0,
        peak_predators: 0,
      ),
      world: env.world,
    )
  #(model, effect.none())
}

// MESSAGES --------------------------------------------------------------------

pub type Message {
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
      html.div(
        [
          attribute.style("position", "relative"),
          attribute.style("width", "100%"),
          attribute.style("display", "flex"),
          attribute.style("justify-content", "center"),
        ],
        [
          render_grid(model.organisms),
          case model.organisms.finished {
            True -> render_stats_overlay(model.organisms)
            False -> element.fragment([])
          },
        ],
      ),
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
      html.text(
        "  |  Births: "
        <> int.to_string(s.births)
        <> "  Deaths: "
        <> int.to_string(s.deaths),
      ),
    ]),
    html.div([attribute.style("margin-top", "0.25rem")], [
      html.text(
        "\u{1F9E0} "
        <> snapshot.llm_model
        <> "  |  "
        <> "Calls: "
        <> int.to_string(snapshot.llm_calls)
        <> "  "
        <> "Errors: "
        <> int.to_string(snapshot.llm_errors)
        <> "  |  "
        <> "Queue: "
        <> int.to_string(snapshot.llm_queue)
        <> "  "
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

  let all_cells = list.append(list.append(plant_cells, herb_cells), pred_cells)

  html.svg(
    [
      attribute(
        "viewBox",
        "0 0 " <> int.to_string(view_size) <> " " <> int.to_string(view_size),
      ),
      attribute("width", "100%"),
      attribute("height", "100%"),
      attribute("xmlns", "http://www.w3.org/2000/svg"),
      attribute("style", "background: #111827; border-radius: 8px;"),
    ],
    all_cells,
  )
}

// --- Statistics Overlay ---

fn render_stats_overlay(snapshot: WorldSnapshot) -> Element(Message) {
  let s = snapshot.stats
  let event_items = render_event_list(snapshot.events)
  let sparkline_svg = render_sparkline(snapshot.pop_history)

  html.div([attribute.id("stats-overlay")], [
    html.div([attribute.class("overlay-backdrop")], []),
    html.div([attribute.class("overlay-panel")], [
      html.h2([], [html.text("\u{2620}\u{FE0F} Extinction Event")]),
      html.p([attribute.class("overlay-subtitle")], [
        html.text("All animals perished at tick " <> int.to_string(s.tick)),
      ]),

      // Summary grid
      html.div([attribute.class("overlay-grid")], [
        render_stat_card("Ticks Survived", int.to_string(s.tick)),
        render_stat_card("Total Births", int.to_string(s.births)),
        render_stat_card("Total Deaths", int.to_string(s.deaths)),
        render_stat_card(
          "Peak \u{1F33F} Plants",
          int.to_string(snapshot.peak_plants),
        ),
        render_stat_card(
          "Peak \u{1F430} Herbivores",
          int.to_string(snapshot.peak_herbivores),
        ),
        render_stat_card(
          "Peak \u{1F43A} Predators",
          int.to_string(snapshot.peak_predators),
        ),
      ]),

      // Population sparkline
      html.div([attribute.class("overlay-section")], [
        html.h3([], [html.text("Population Over Time")]),
        sparkline_svg,
      ]),

      // Event timeline
      html.div([attribute.class("overlay-section")], [
        html.h3([], [html.text("Event Timeline")]),
        html.div([attribute.class("event-list")], event_items),
      ]),

      // Reset button
      html.div([attribute.class("overlay-actions")], [
        html.button(
          [
            event.on_click(UserClickedReset),
            attribute.class("reset-btn"),
          ],
          [html.text("\u{1F504} New Simulation")],
        ),
      ]),
    ]),
  ])
}

fn render_stat_card(label: String, value: String) -> Element(Message) {
  html.div([attribute.class("stat-card")], [
    html.div([attribute.class("stat-value")], [html.text(value)]),
    html.div([attribute.class("stat-label")], [html.text(label)]),
  ])
}

fn render_event_list(events: List(Event)) -> List(Element(Message)) {
  events
  |> list.reverse()
  |> list.map(fn(event) {
    let #(icon, text) = event_display(event)
    html.div([attribute.class("event-item")], [
      html.span([attribute.class("event-icon")], [html.text(icon)]),
      html.span([attribute.class("event-text")], [html.text(text)]),
    ])
  })
}

fn event_display(event: Event) -> #(String, String) {
  case event {
    Extinction(tick:) -> #(
      "\u{2620}\u{FE0F}",
      "Extinction at tick " <> int.to_string(tick),
    )
    LastHerbDied(tick:) -> #(
      "\u{1F430}",
      "Last herbivore died at tick " <> int.to_string(tick),
    )
    LastPredDied(tick:) -> #(
      "\u{1F43A}",
      "Last predator died at tick " <> int.to_string(tick),
    )
    FirstDeath(tick:) -> #(
      "\u{1F480}",
      "First death at tick " <> int.to_string(tick),
    )
    FirstBirth(tick:) -> #(
      "\u{1F423}",
      "First birth at tick " <> int.to_string(tick),
    )
    PeakPopulation(tick:, label:, count:) -> #(
      "\u{1F4C8}",
      "Peak "
        <> label
        <> ": "
        <> int.to_string(count)
        <> " at tick "
        <> int.to_string(tick),
    )
    FirstHerbBorn(tick:) -> #(
      "\u{1F430}",
      "First herbivore born at tick " <> int.to_string(tick),
    )
    FirstPredBorn(tick:) -> #(
      "\u{1F43A}",
      "First predator born at tick " <> int.to_string(tick),
    )
  }
}

/// Render a simple sparkline SVG showing population history.
fn render_sparkline(history: List(PopSample)) -> Element(Message) {
  let history = list.reverse(history)
  let max_pop = find_max_population(history)
  let width = 400
  let height = 120

  case max_pop > 0 && list.length(history) > 1 {
    False -> html.div([], [html.text("No data")])
    True -> {
      let total_samples = list.length(history)
      // Build polyline points for each population type
      let plant_points =
        make_sparkline_points(
          history,
          fn(s) { s.plants },
          total_samples,
          width,
          height,
          max_pop,
        )
      let herb_points =
        make_sparkline_points(
          history,
          fn(s) { s.herbivores },
          total_samples,
          width,
          height,
          max_pop,
        )
      let pred_points =
        make_sparkline_points(
          history,
          fn(s) { s.predators },
          total_samples,
          width,
          height,
          max_pop,
        )

      let points_to_string = fn(points: List(#(Int, Int))) -> String {
        points
        |> list.map(fn(p) {
          let #(px, py) = p
          int.to_string(px) <> "," <> int.to_string(py)
        })
        |> string.join(" ")
      }

      html.svg(
        [
          attribute(
            "viewBox",
            "0 0 " <> int.to_string(width) <> " " <> int.to_string(height),
          ),
          attribute("width", "100%"),
          attribute("height", "120"),
          attribute("xmlns", "http://www.w3.org/2000/svg"),
          attribute("style", "background: #0f172a; border-radius: 4px;"),
        ],
        [
          // Plants line (green)
          svg.polyline([
            attribute("fill", "none"),
            attribute("stroke", "#22c55e"),
            attribute("stroke-width", "1.5"),
            attribute("points", points_to_string(plant_points)),
          ]),
          // Herbivores line (blue)
          svg.polyline([
            attribute("fill", "none"),
            attribute("stroke", "#3b82f6"),
            attribute("stroke-width", "1.5"),
            attribute("points", points_to_string(herb_points)),
          ]),
          // Predators line (red)
          svg.polyline([
            attribute("fill", "none"),
            attribute("stroke", "#ef4444"),
            attribute("stroke-width", "1.5"),
            attribute("points", points_to_string(pred_points)),
          ]),
          // Legend
          svg.text(
            [
              attribute("x", "10"),
              attribute("y", "15"),
              attribute("fill", "#22c55e"),
              attribute("font-size", "10"),
            ],
            "\u{1F33F} Plants",
          ),
          svg.text(
            [
              attribute("x", "90"),
              attribute("y", "15"),
              attribute("fill", "#3b82f6"),
              attribute("font-size", "10"),
            ],
            "\u{1F430} Herbs",
          ),
          svg.text(
            [
              attribute("x", "160"),
              attribute("y", "15"),
              attribute("fill", "#ef4444"),
              attribute("font-size", "10"),
            ],
            "\u{1F43A} Preds",
          ),
        ],
      )
    }
  }
}

fn find_max_population(history: List(PopSample)) -> Int {
  history
  |> list.fold(0, fn(max, sample) {
    int.max(
      max,
      int.max(sample.plants, int.max(sample.herbivores, sample.predators)),
    )
  })
}

fn make_sparkline_points(
  history: List(PopSample),
  extract: fn(PopSample) -> Int,
  total: Int,
  width: Int,
  height: Int,
  max_val: Int,
) -> List(#(Int, Int)) {
  let padding = 4
  let usable_height = height - padding * 2
  history
  |> list.index_map(fn(sample, i) {
    let x = case total <= 1 {
      True -> padding
      False ->
        float.truncate(
          int.to_float(padding)
          +. int.to_float(i)
          *. int.to_float(width - padding * 2)
          /. int.to_float(total - 1),
        )
    }
    let val = extract(sample)
    let y = case max_val == 0 {
      True -> height - padding
      False ->
        float.truncate(
          int.to_float(height - padding)
          -. int.to_float(val)
          *. int.to_float(usable_height)
          /. int.to_float(max_val),
        )
    }
    #(x, y)
  })
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

  /* --- Statistics Overlay --- */
  #stats-overlay {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    bottom: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    z-index: 10;
  }
  .overlay-backdrop {
    position: absolute;
    top: 0; left: 0; right: 0; bottom: 0;
    background: rgba(0, 0, 0, 0.7);
    border-radius: 8px;
  }
  .overlay-panel {
    position: relative;
    background: #1e293b;
    border: 1px solid #334155;
    border-radius: 12px;
    padding: 1.5rem 2rem;
    max-width: 600px;
    width: 90%;
    max-height: 85%;
    overflow-y: auto;
    box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
  }
  .overlay-panel h2 {
    font-size: 1.4rem;
    margin-bottom: 0.25rem;
    color: #f87171;
  }
  .overlay-subtitle {
    font-size: 0.9rem;
    color: #94a3b8;
    margin-bottom: 1rem;
  }
  .overlay-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 0.75rem;
    margin-bottom: 1.25rem;
  }
  .stat-card {
    background: #0f172a;
    border-radius: 8px;
    padding: 0.75rem;
    text-align: center;
  }
  .stat-value {
    font-size: 1.5rem;
    font-weight: 700;
    color: #e2e8f0;
  }
  .stat-label {
    font-size: 0.75rem;
    color: #64748b;
    margin-top: 0.25rem;
  }
  .overlay-section {
    margin-bottom: 1rem;
  }
  .overlay-section h3 {
    font-size: 0.95rem;
    color: #cbd5e1;
    margin-bottom: 0.5rem;
  }
  .event-list {
    max-height: 160px;
    overflow-y: auto;
  }
  .event-item {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    padding: 0.3rem 0;
    font-size: 0.85rem;
    border-bottom: 1px solid #1e293b;
  }
  .event-icon { font-size: 1rem; }
  .event-text { color: #94a3b8; }
  .overlay-actions {
    margin-top: 1.25rem;
    text-align: center;
  }
  .reset-btn {
    padding: 0.6rem 1.5rem !important;
    font-size: 1rem !important;
    background: #3b82f6 !important;
    border-color: #2563eb !important;
    color: white !important;
    border-radius: 0.5rem;
    cursor: pointer;
  }
  .reset-btn:hover {
    background: #2563eb !important;
  }
  "
}
