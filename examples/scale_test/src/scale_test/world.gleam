//// World actor — owns the grid state, ticks the simulation,
//// broadcasts state snapshots to connected Lustre runtimes via group_registry.

import gleam/erlang/process.{
  type Subject, type Timer, cancel_timer, send_after,
}
import gleam/list
import gleam/otp/actor
import group_registry.{type GroupRegistry}
import scale_test/grid.{
  type Grid, Herbivore, Plant, Predator, count_by_type, to_list,
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
  )
}

pub type WorldModel {
  WorldModel(
    grid: Grid,
    stats: Stats,
    paused: Bool,
    tick_speed: Int,
    self_subject: Subject(WorldMsg),
    registry: GroupRegistry(WorldSnapshot),
    /// Handle for the pending tick timer, so we can cancel before rescheduling.
    tick_timer: Timer,
    /// Cumulative birth/death counters.
    total_births: Int,
    total_deaths: Int,
  )
}

/// Start the world actor. Pass a group_registry so the world can broadcast
/// snapshots to connected Lustre runtimes after each tick.
pub fn start(
  registry: GroupRegistry(WorldSnapshot),
) -> actor.StartResult(Subject(WorldMsg)) {
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
        registry:,
        tick_timer:,
        total_births: 0,
        total_deaths: 0,
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
          let grid = apply_random_intents(grid, rethinks)
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
      actor.continue(WorldModel(..model, tick_speed: speed.ms))
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
  }
}

/// Broadcast the current state as a WorldSnapshot to all connected clients.
fn broadcast_snapshot(model: WorldModel) -> Nil {
  let snapshot = make_snapshot(model)
  let members = group_registry.members(model.registry, "ecosystem")
  use member <- list.each(members)
  process.send(member, snapshot)
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
  )
}

fn compute_stats(tick: Int, grid: Grid, births: Int, deaths: Int) -> Stats {
  let #(plants, herbivores, predators) = count_by_type(grid)
  Stats(tick:, plants:, herbivores:, predators:, births:, deaths:)
}
