//// World actor — owns the grid state, ticks the simulation,
//// broadcasts state snapshots to connected Lustre runtimes via direct subscriptions.

import gleam/dict
import gleam/erlang/process.{
  type Subject, type Timer, cancel_timer, send_after,
}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import scale_test/grid.{
  type Grid, Herbivore, Organism, Plant, Predator, count_by_type, get,
  to_list,
}
import scale_test/intent.{type Intent}
import scale_test/protocol.{
  type SchedulerMsg, Enqueue, SetConcurrency,
}
import scale_test/sim.{
  TickResult, apply_random_intents, populate, tick,
}

pub type TickSpeed {
  TickSpeed(ms: Int)
}

pub type Stats {
  Stats(
    tick: Int,
    plants: Int,
    herbivores: Int,
    predators: Int,
    births: Int,
    deaths: Int,
  )
}

/// Messages the world actor can receive.
pub type WorldMsg {
  /// Internal tick message from the timer
  Tick
  /// Pause/resume the simulation
  TogglePause
  /// Change tick speed
  SetTickSpeed(TickSpeed)
  /// Reset with given population counts
  Reset(plant_count: Int, herb_count: Int, pred_count: Int)
  /// Update an organism's intent (from scheduler/LLM)
  UpdateIntent(pos: #(Int, Int), intent: Intent)
  /// Update LLM stats from scheduler
  UpdateLLMStats(llm_calls: Int, llm_errors: Int, llm_queue: Int, llm_in_flight: Int)
  /// Set the scheduler subject for sending re-think requests
  SetScheduler(Subject(SchedulerMsg), model_name: String)
  /// Change LLM concurrency
  SetLLMConcurrency(Int)
  /// Subscribe to snapshot broadcasts
  Subscribe(Subject(WorldSnapshot))
}

/// Lightweight snapshot for sending to the UI.
pub type WorldSnapshot {
  WorldSnapshot(
    plants: List(#(#(Int, Int), Int)),
    herbivores: List(#(#(Int, Int), Int)),
    predators: List(#(#(Int, Int), Int)),
    stats: Stats,
    paused: Bool,
    tick_speed: Int,
    llm_calls: Int,
    llm_errors: Int,
    llm_queue: Int,
    llm_in_flight: Int,
    llm_max_concurrency: Int,
    llm_model: String,
  )
}

pub type WorldModel {
  WorldModel(
    grid: Grid,
    stats: Stats,
    paused: Bool,
    tick_speed: Int,
    self_subject: Subject(WorldMsg),
    /// Handle for the pending tick timer, so we can cancel before rescheduling.
    tick_timer: Timer,
    /// Cumulative birth/death counters.
    total_births: Int,
    total_deaths: Int,
    /// Optional scheduler for LLM-driven decisions.
    scheduler: option.Option(Subject(SchedulerMsg)),
    /// Cached LLM stats from scheduler
    llm_calls: Int,
    llm_errors: Int,
    llm_queue: Int,
    llm_in_flight: Int,
    llm_max_concurrency: Int,
    llm_model: String,
    /// Direct subscribers for snapshot broadcasts
    subscribers: List(Subject(WorldSnapshot)),
  )
}

/// Start the world actor.
pub fn start() -> actor.StartResult(Subject(WorldMsg)) {
  actor.new_with_initialiser(
    5000,
    fn(subject) {
      let initial_grid = populate(300, 20, 10)
      let initial_stats = compute_stats(0, initial_grid, 0, 0)
      let tick_timer = send_after(subject, 200, Tick)
      let model = WorldModel(
        grid: initial_grid,
        stats: initial_stats,
        paused: False,
        tick_speed: 200,
        self_subject: subject,
        tick_timer:,
        total_births: 0,
        total_deaths: 0,
        scheduler: None,
        llm_calls: 0,
        llm_errors: 0,
        llm_queue: 0,
        llm_in_flight: 0,
        llm_max_concurrency: 8,
        llm_model: "",
        subscribers: [],
      )
      // Broadcast initial state
      broadcast_snapshot(model)
      actor.initialised(model)
        |> actor.returning(subject)
        |> Ok
    },
  )
  |> actor.on_message(handle_message)
  |> actor.start
}

/// Cancel any pending tick timer and schedule a new one.
fn schedule_tick(model: WorldModel) -> WorldModel {
  let _ = cancel_timer(model.tick_timer)
  WorldModel(
    ..model,
    tick_timer: send_after(model.self_subject, model.tick_speed, Tick),
  )
}

fn handle_message(model: WorldModel, msg: WorldMsg) ->
    actor.Next(WorldModel, WorldMsg) {
  case msg {
    Tick -> {
      case model.paused {
        True -> {
          actor.continue(schedule_tick(model))
        }
        False -> {
          let TickResult(grid, rethinks, births, deaths) =
            tick(model.grid)
          // Send rethinks to scheduler if available, otherwise use random intents
          // Also apply random intents immediately for all rethinks so organisms
          // don't sit idle while waiting for LLM responses
          let grid = case model.scheduler {
            Some(scheduler) -> {
              send_to_scheduler(scheduler, model.grid, rethinks)
              apply_random_intents(grid, rethinks)
            }
            None -> apply_random_intents(grid, rethinks)
          }
          let new_tick = model.stats.tick + 1
          let total_births = model.total_births + births
          let total_deaths = model.total_deaths + deaths
          let stats = compute_stats(new_tick, grid, total_births, total_deaths)
          let model =
            WorldModel(..model, grid:, stats:, total_births:, total_deaths:)
          let model = schedule_tick(model)
          broadcast_snapshot(model)
          actor.continue(model)
        }
      }
    }

    TogglePause -> {
      let model = WorldModel(..model, paused: !model.paused)
      broadcast_snapshot(model)
      actor.continue(model)
    }

    SetTickSpeed(speed) -> {
      let model = WorldModel(..model, tick_speed: speed.ms)
      let model = schedule_tick(model)
      actor.continue(model)
    }

    Reset(plant_count, herb_count, pred_count) -> {
      let grid = populate(plant_count, herb_count, pred_count)
      let stats = compute_stats(0, grid, 0, 0)
      let model = WorldModel(
        ..model,
        grid:,
        stats:,
        paused: False,
        total_births: 0,
        total_deaths: 0,
      )
      let model = schedule_tick(model)
      broadcast_snapshot(model)
      actor.continue(model)
    }

    UpdateIntent(pos, intent) -> {
      case get(model.grid, pos) {
        Ok(organism) -> {
          let updated = Organism(..organism, intent:)
          let grid = dict.insert(model.grid, pos, updated)
          let model = WorldModel(..model, grid:)
          actor.continue(model)
        }
        Error(_) -> actor.continue(model)
      }
    }

    UpdateLLMStats(llm_calls:, llm_errors:, llm_queue:, llm_in_flight:) -> {
      let model = WorldModel(..model, llm_calls:, llm_errors:, llm_queue:, llm_in_flight:)
      actor.continue(model)
    }

    SetScheduler(scheduler, model_name:) -> {
      let model = WorldModel(
        ..model,
        scheduler: Some(scheduler),
        llm_model: model_name,
      )
      actor.continue(model)
    }

    SetLLMConcurrency(n) -> {
      case model.scheduler {
        Some(scheduler) ->
          process.send(scheduler, SetConcurrency(n))
        None -> Nil
      }
      let model = WorldModel(..model, llm_max_concurrency: n)
      actor.continue(model)
    }

    Subscribe(sub) -> {
      let model = WorldModel(..model, subscribers: [sub, ..model.subscribers])
      // Send current snapshot immediately
      process.send(sub, make_snapshot(model))
      actor.continue(model)
    }
  }
}

/// Broadcast the current state as a WorldSnapshot to all connected clients.
fn broadcast_snapshot(model: WorldModel) -> Nil {
  let snapshot = make_snapshot(model)
  // Send to direct subscribers
  use sub <- list.each(model.subscribers)
  process.send(sub, snapshot)
}

fn make_snapshot(model: WorldModel) -> WorldSnapshot {
  let all = to_list(model.grid)
  let plants = list.filter(all, fn(o) { o.otype == Plant })
  let herbs = list.filter(all, fn(o) { o.otype == Herbivore })
  let preds = list.filter(all, fn(o) { o.otype == Predator })

  WorldSnapshot(
    plants: list.map(plants, fn(o) { #(o.pos, o.energy) }),
    herbivores: list.map(herbs, fn(o) { #(o.pos, o.energy) }),
    predators: list.map(preds, fn(o) { #(o.pos, o.energy) }),
    stats: model.stats,
    paused: model.paused,
    tick_speed: model.tick_speed,
    llm_calls: model.llm_calls,
    llm_errors: model.llm_errors,
    llm_queue: model.llm_queue,
    llm_in_flight: model.llm_in_flight,
    llm_max_concurrency: model.llm_max_concurrency,
    llm_model: model.llm_model,
  )
}

fn compute_stats(tick: Int, grid: Grid, births: Int, deaths: Int) -> Stats {
  let #(plants, herbivores, predators) = count_by_type(grid)
  Stats(tick:, plants:, herbivores:, predators:, births:, deaths:)
}

/// Send re-think requests to the scheduler for each position.
fn send_to_scheduler(
  scheduler: Subject(SchedulerMsg),
  grid: Grid,
  rethinks: List(#(Int, Int)),
) -> Nil {
  let decisions =
    rethinks
    |> list.filter_map(fn(pos) {
      case get(grid, pos) {
        Ok(organism) -> Ok(#(pos, organism))
        Error(_) -> Error(Nil)
      }
    })
  case decisions {
    [] -> Nil
    _ -> process.send(scheduler, Enqueue(decisions, grid:))
  }
}

