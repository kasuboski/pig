//// Decision scheduler — manages LLM call queue for agent decisions.
//// Receives re-think requests from the World actor, queues them,
//// and processes them with configurable concurrency.
//// Batches multiple organisms into a single LLM call for throughput.

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import pig
import pig/ai/message
import pig/ai/openai
import scale_test/grid.{
  type Grid, type Organism, type OrganismType, type Position, Herbivore,
  Plant, Predator, get, wrap_position,
}
import scale_test/intent
import scale_test/protocol.{
  type SchedulerMsg, type WorldCmd, Enqueue, GetStats,
  LlmCompleted, ProcessQueue, SchedulerStats, SetConcurrency, SetWorld,
  UpdateIntent, UpdateLLMStats,
}
import scale_test/prompt

/// How many organisms to pack into a single LLM call.
const batch_size = 10

/// A queued decision request with grid context.
type Decision {
  Decision(
    pos: Position,
    organism: Organism,
    nearby: List(#(String, Option(OrganismType))),
    food_hint: String,
  )
}

pub opaque type SchedulerModel {
  SchedulerModel(
    queue: List(Decision),
    in_flight: Int,
    max_concurrency: Int,
    world: Option(Subject(WorldCmd)),
    base_url: String,
    api_key: String,
    model: String,
    self: Subject(SchedulerMsg),
    /// Track organisms currently being processed to avoid duplicates
    processing: dict.Dict(Position, Organism),
    /// LLM stats
    total_calls: Int,
    total_errors: Int,
  )
}

/// Start the scheduler actor.
pub fn start(
  concurrency: Int,
  base_url base_url: String,
  api_key api_key: String,
  model model: String,
) -> actor.StartResult(Subject(SchedulerMsg)) {
  actor.new_with_initialiser(5000, fn(self) {
    let model = SchedulerModel(
      queue: [],
      in_flight: 0,
      max_concurrency: concurrency,
      world: None,
      base_url:,
      api_key:,
      model:,
      self:,
      processing: dict.new(),
      total_calls: 0,
      total_errors: 0,
    )
    actor.initialised(model)
      |> actor.returning(self)
      |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(model: SchedulerModel, msg: SchedulerMsg) ->
    actor.Next(SchedulerModel, SchedulerMsg) {
  case msg {
    Enqueue(decisions, grid) -> {
      let new_items =
        decisions
        |> list.filter_map(fn(entry) {
          let #(pos, organism) = entry
          case dict.has_key(model.processing, pos) {
            True -> Error(Nil)
            False -> {
              let nearby = build_nearby(organism, grid)
              let food_hint = find_nearest_food(organism, grid)
              Ok(Decision(pos:, organism:, nearby:, food_hint:))
            }
          }
        })
      let queue = list.append(model.queue, new_items)
      let model = SchedulerModel(..model, queue:)
      let model = maybe_spawn_calls(model)
      // Push stats so world sees queue filling up
      case model.world {
        Some(world) ->
          process.send(
            world,
            UpdateLLMStats(
              llm_calls: model.total_calls,
              llm_errors: model.total_errors,
              llm_queue: list.length(model.queue),
              llm_in_flight: model.in_flight,
            ),
          )
        None -> Nil
      }
      actor.continue(model)
    }

    LlmCompleted(positions, results) -> {
      // results is a list of #(Position, Result(String, Nil))
      // Send each intent to world and count stats
      let new_calls = model.total_calls + list.length(results)
      let errors =
        results
        |> list.filter(fn(entry) {
          let #(_, result) = entry
          case result {
            Ok(_) -> False
            Error(_) -> True
          }
        })
      let new_errors = model.total_errors + list.length(errors)

      // Send intents to world
      case model.world {
        Some(world) -> {
          list.each(results, fn(entry) {
            let #(pos, result) = entry
            let intent = case result {
              Ok(response) -> intent.parse(response)
              Error(_) -> intent.random()
            }
            process.send(world, UpdateIntent(pos, intent))
          })
        }
        None -> Nil
      }

      // Remove from processing dict
      let processing =
        list.fold(positions, model.processing, fn(proc, pos) {
          dict.delete(proc, pos)
        })

      let in_flight = model.in_flight - 1
      let model = SchedulerModel(
        ..model,
        in_flight:,
        processing:,
        total_calls: new_calls,
        total_errors: new_errors,
      )
      let model = maybe_spawn_calls(model)

      // Log batch results
      let ok_count = list.length(results) - list.length(errors)
      io.println(
        "LLM batch: "
        <> int.to_string(ok_count)
        <> "/"
        <> int.to_string(list.length(results))
        <> " ok",
      )

      // Push stats
      case model.world {
        Some(world) ->
          process.send(
            world,
            UpdateLLMStats(
              llm_calls: model.total_calls,
              llm_errors: model.total_errors,
              llm_queue: list.length(model.queue),
              llm_in_flight: model.in_flight,
            ),
          )
        None -> Nil
      }
      actor.continue(model)
    }

    SetConcurrency(n) -> {
      let model = SchedulerModel(..model, max_concurrency: n)
      let model = maybe_spawn_calls(model)
      actor.continue(model)
    }

    ProcessQueue -> {
      let model = maybe_spawn_calls(model)
      actor.continue(model)
    }

    SetWorld(world) -> {
      actor.continue(SchedulerModel(..model, world: Some(world)))
    }

    GetStats(reply_to) -> {
      let stats = SchedulerStats(
        llm_calls: model.total_calls,
        llm_errors: model.total_errors,
        queue_depth: list.length(model.queue),
        in_flight: model.in_flight,
        max_concurrency: model.max_concurrency,
        model: model.model,
      )
      process.send(reply_to, stats)
      actor.continue(model)
    }
  }
}

/// Spawn batched LLM calls if we have capacity and items in queue.
fn maybe_spawn_calls(model: SchedulerModel) -> SchedulerModel {
  case model.in_flight < model.max_concurrency && model.queue != [] {
    False -> model
    True -> {
      // Take up to batch_size items from queue
      let batch = list.take(model.queue, batch_size)
      let rest = list.drop(model.queue, batch_size)
      case batch {
        [] -> model
        _ -> {
          // Build the batch prompt
          let batch_entries =
            list.map(batch, fn(d) {
              #(d.organism, d.nearby, d.food_hint)
            })
          let prompt_text = prompt.build_batch(batch_entries)

          // Collect positions and organisms
          let positions = list.map(batch, fn(d) { d.pos })
          let otype = case batch {
            [first, ..] -> first.organism.otype
            [] -> Plant
          }

          let self = model.self
          let base_url = model.base_url
          let api_key = model.api_key
          let model_name = model.model

          let _ = process.spawn_unlinked(fn() {
            let result = run_llm_call(
              prompt_text,
              base_url,
              api_key,
              model_name,
              otype,
            )
            // Parse batch result into individual responses
            let results = case result {
              Ok(response) -> {
                let parsed = prompt.parse_batch(response, list.length(batch))
                list.zip(positions, list.map(parsed, fn(s) { Ok(s) }))
              }
              Error(_) ->
                list.map(positions, fn(pos) { #(pos, Error(Nil)) })
            }
            process.send(self, LlmCompleted(positions, results))
          })

          let processing =
            list.fold(batch, model.processing, fn(proc, d) {
              dict.insert(proc, d.pos, d.organism)
            })
          let model = SchedulerModel(
            ..model,
            queue: rest,
            in_flight: model.in_flight + 1,
            processing:,
          )
          maybe_spawn_calls(model)
        }
      }
    }
  }
}

/// Run an LLM call — creates a one-shot pig agent.
fn run_llm_call(
  prompt_text: String,
  base_url: String,
  api_key: String,
  model_name: String,
  otype: OrganismType,
) -> Result(String, Nil) {
  let provider =
    openai.provider_with_base_url(api_key, model_name, base_url)
  let cfg =
    pig.new(provider.call)
    |> pig.with_model(model_name)
    |> pig.with_system_prompt(system_prompt_for(otype))

  case pig.start(cfg) {
    Ok(agent) -> {
      let result =
        case pig.run_with_timeout(agent, prompt_text, 10_000) {
          Ok(message.Assistant(content:, ..)) -> Ok(content)
          Ok(_) -> Error(Nil)
          Error(_) -> Error(Nil)
        }
      pig.stop(agent)
      result
    }
    Error(_) -> Error(Nil)
  }
}

fn system_prompt_for(otype: OrganismType) -> String {
  case otype {
    Herbivore ->
      "You are controlling multiple herbivore rabbits in an ecosystem simulation. For each, decide: eat (if plant nearby), reproduce (if healthy), move toward food, or rest. Respond with one word per line."
    Predator ->
      "You are controlling multiple predator wolves in an ecosystem simulation. For each, decide: eat (if herbivore nearby), reproduce (if healthy), move toward prey, or rest. Respond with one word per line."
    Plant -> "You are a plant. You do not think."
  }
}

/// Build the nearby context for a prompt using the grid snapshot.
fn build_nearby(
  organism: Organism,
  grid: Grid,
) -> List(#(String, Option(OrganismType))) {
  let #(x, y) = organism.pos
  let directions = [
    #("N", #(x, y - 1)),
    #("S", #(x, y + 1)),
    #("E", #(x + 1, y)),
    #("W", #(x - 1, y)),
  ]
  list.map(directions, fn(entry) {
    let #(label, pos) = entry
    case get(grid, pos) {
      Ok(n) -> #(label, Some(n.otype))
      Error(_) -> #(label, None)
    }
  })
}

/// Find the nearest food source within a radius and return a direction hint.
/// Returns something like "food:2N" or "prey:3SW" or empty string if none found.
fn find_nearest_food(organism: Organism, grid: Grid) -> String {
  let food_type = case organism.otype {
    Herbivore -> Plant
    Predator -> Herbivore
    Plant -> Plant
  }
  let #(ox, oy) = organism.pos
  // Search in expanding rings from radius 1 to 5
  case find_in_radius(grid, ox, oy, food_type, 1, 5) {
    Ok(#(dx, dy)) -> {
      let label = case food_type {
        Plant -> "food"
        Herbivore -> "prey"
        Predator -> "danger"
      }
      let dir = direction_label(dx, dy)
      let dist = int.max(int.absolute_value(dx), int.absolute_value(dy))
      label <> ":" <> int.to_string(dist) <> dir
    }
    Error(Nil) -> "no-food"
  }
}

/// Search for a food type in expanding radius rings.
fn find_in_radius(
  grid: Grid,
  cx: Int,
  cy: Int,
  food_type: OrganismType,
  current: Int,
  max: Int,
) -> Result(#(Int, Int), Nil) {
  case current > max {
    True -> Error(Nil)
    False -> {
      case scan_ring(grid, cx, cy, food_type, current) {
        Ok(delta) -> Ok(delta)
        Error(Nil) -> find_in_radius(grid, cx, cy, food_type, current + 1, max)
      }
    }
  }
}

/// Scan all positions at exactly `radius` distance from (cx, cy).
fn scan_ring(
  grid: Grid,
  cx: Int,
  cy: Int,
  food_type: OrganismType,
  radius: Int,
) -> Result(#(Int, Int), Nil) {
  let r = radius
  // Collect all offsets at distance r (perimeter of square)
  let offsets = ring_offsets(r)
  let hits =
    offsets
    |> list.filter_map(fn(offset) {
      let #(dx, dy) = offset
      check_cell(grid, cx + dx, cy + dy, food_type, dx, dy)
    })
  case hits {
    [first, ..] -> Ok(first)
    [] -> Error(Nil)
  }
}

/// Generate all (dx, dy) offsets on the perimeter of a square at distance r.
fn ring_offsets(r: Int) -> List(#(Int, Int)) {
  case r {
    0 -> []
    _ -> {
      // Top row: y = -r
      let top = offsets_row(-r, -r, r)
      // Bottom row: y = r
      let bottom = offsets_row(r, -r, r)
      // Left column: x = -r, excluding corners
      let left = offsets_col(-r, -r + 1, r - 1)
      // Right column: x = r, excluding corners
      let right = offsets_col(r, -r + 1, r - 1)
      list.append(list.append(list.append(top, bottom), left), right)
    }
  }
}

fn offsets_row(y: Int, x_from: Int, x_to: Int) -> List(#(Int, Int)) {
  case x_from > x_to {
    True -> []
    False -> [#(x_from, y), ..offsets_row(y, x_from + 1, x_to)]
  }
}

fn offsets_col(x: Int, y_from: Int, y_to: Int) -> List(#(Int, Int)) {
  case y_from > y_to {
    True -> []
    False -> [#(x, y_from), ..offsets_col(x, y_from + 1, y_to)]
  }
}

fn check_cell(
  grid: Grid,
  x: Int,
  y: Int,
  food_type: OrganismType,
  dx: Int,
  dy: Int,
) -> Result(#(Int, Int), Nil) {
  let pos = wrap_position(#(x, y))
  case get(grid, pos) {
    Ok(o) if o.otype == food_type -> Ok(#(dx, dy))
    _ -> Error(Nil)
  }
}

/// Convert a dx,dy offset into a compass direction string.
fn direction_label(dx: Int, dy: Int) -> String {
  let ns = case dy < 0 {
    True -> "N"
    False -> case dy > 0 {
      True -> "S"
      False -> ""
    }
  }
  let ew = case dx < 0 {
    True -> "W"
    False -> case dx > 0 {
      True -> "E"
      False -> ""
    }
  }
  ns <> ew
}
