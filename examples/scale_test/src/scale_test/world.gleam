//// World actor — owns the grid state, ticks the simulation,
//// broadcasts state snapshots to connected Lustre runtimes via direct subscriptions.

import gleam/dict
import gleam/erlang/process.{type Subject, type Timer, cancel_timer, send_after}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import scale_test/grid.{
  type Grid, Herbivore, Organism, Plant, Predator, count_by_type, get, to_list,
}
import scale_test/intent.{type Intent}
import scale_test/protocol.{type SchedulerMsg, Enqueue, SetConcurrency}
import scale_test/runtime_stats
import scale_test/sim.{TickResult, apply_random_intents, populate, tick}

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

/// A recorded event in the simulation history.
pub type Event {
  /// First herbivore born
  FirstHerbBorn(tick: Int)
  /// First predator born
  FirstPredBorn(tick: Int)
  /// Last herbivore died
  LastHerbDied(tick: Int)
  /// Last predator died
  LastPredDied(tick: Int)
  /// All animals went extinct (simulation ended)
  Extinction(tick: Int)
  /// Population milestone: a type reached a new peak
  PeakPopulation(tick: Int, label: String, count: Int)
  /// First death in the simulation
  FirstDeath(tick: Int)
  /// First birth in the simulation
  FirstBirth(tick: Int)
}

/// A population sample at a given tick.
pub type PopSample {
  PopSample(tick: Int, plants: Int, herbivores: Int, predators: Int)
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
  UpdateLLMStats(
    llm_calls: Int,
    llm_errors: Int,
    llm_queue: Int,
    llm_in_flight: Int,
  )
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
    /// Whether the simulation has ended (all animals dead)
    finished: Bool,
    /// Recorded events during the run
    events: List(Event),
    /// Population history samples
    pop_history: List(PopSample),
    /// Peak population counts
    peak_plants: Int,
    peak_herbivores: Int,
    peak_predators: Int,
    /// Runtime scale metrics (sampled at extinction)
    beam_processes: Int,
    total_memory_bytes: Int,
    run_queue: Int,
    wall_clock_elapsed_ms: Int,
    peak_llm_queue: Int,
    peak_llm_in_flight: Int,
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
    /// Whether the simulation has finished (all animals died)
    finished: Bool,
    /// Recorded events during the run
    events: List(Event),
    /// Population history samples (sampled every N ticks)
    pop_history: List(PopSample),
    /// Peak population counts
    peak_plants: Int,
    peak_herbivores: Int,
    peak_predators: Int,
    /// Tracking helpers for first-event detection
    had_first_death: Bool,
    had_first_birth: Bool,
    had_first_herb_born: Bool,
    had_first_pred_born: Bool,
    /// Previous tick herbivore/predator counts (for extinction detection)
    prev_herbivores: Int,
    prev_predators: Int,
    /// Start time for wall-clock elapsed (monotonic ms)
    start_time_ms: Int,
    /// Runtime metrics sampled at extinction
    final_beam_processes: Int,
    final_total_memory_bytes: Int,
    final_run_queue: Int,
    final_wall_clock_ms: Int,
    /// Peak LLM scheduler metrics
    peak_llm_queue: Int,
    peak_llm_in_flight: Int,
  )
}

/// How often to sample population history (every N ticks)
const pop_sample_interval = 5

/// Start the world actor.
pub fn start() -> actor.StartResult(Subject(WorldMsg)) {
  actor.new_with_initialiser(5000, fn(subject) {
    let initial_grid = populate(300, 20, 10)
    let initial_stats = compute_stats(0, initial_grid, 0, 0)
    let tick_timer = send_after(subject, 200, Tick)
    let initial_sample =
      PopSample(
        tick: 0,
        plants: initial_stats.plants,
        herbivores: initial_stats.herbivores,
        predators: initial_stats.predators,
      )
    let model =
      WorldModel(
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
        finished: False,
        events: [],
        pop_history: [initial_sample],
        peak_plants: initial_stats.plants,
        peak_herbivores: initial_stats.herbivores,
        peak_predators: initial_stats.predators,
        had_first_death: False,
        had_first_birth: False,
        had_first_herb_born: False,
        had_first_pred_born: False,
        prev_herbivores: initial_stats.herbivores,
        prev_predators: initial_stats.predators,
        start_time_ms: runtime_stats.monotonic_ms(),
        final_beam_processes: 0,
        final_total_memory_bytes: 0,
        final_run_queue: 0,
        final_wall_clock_ms: 0,
        peak_llm_queue: 0,
        peak_llm_in_flight: 0,
      )
    // Broadcast initial state
    broadcast_snapshot(model)
    actor.initialised(model)
    |> actor.returning(subject)
    |> Ok
  })
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

fn handle_message(
  model: WorldModel,
  msg: WorldMsg,
) -> actor.Next(WorldModel, WorldMsg) {
  case msg {
    Tick -> {
      case model.paused || model.finished {
        True -> {
          // Don't schedule another tick if finished
          case model.finished {
            True -> actor.continue(model)
            False -> actor.continue(schedule_tick(model))
          }
        }
        False -> {
          let TickResult(grid, rethinks, births, deaths) = tick(model.grid)
          // Send rethinks to scheduler if available, otherwise use random intents
          let grid = case model.scheduler {
            Some(scheduler) -> {
              send_to_scheduler(scheduler, grid, rethinks)
              apply_random_intents(grid, rethinks)
            }
            None -> apply_random_intents(grid, rethinks)
          }
          let new_tick = model.stats.tick + 1
          let total_births = model.total_births + births
          let total_deaths = model.total_deaths + deaths
          let stats = compute_stats(new_tick, grid, total_births, total_deaths)

          // Record events
          let events = record_events(model, stats, births, deaths)

          // Track peak populations
          let peak_plants = int.max(model.peak_plants, stats.plants)
          let peak_herbivores = int.max(model.peak_herbivores, stats.herbivores)
          let peak_predators = int.max(model.peak_predators, stats.predators)

          // Sample population history
          let pop_history = case new_tick % pop_sample_interval == 0 {
            True -> [
              PopSample(
                tick: new_tick,
                plants: stats.plants,
                herbivores: stats.herbivores,
                predators: stats.predators,
              ),
              ..model.pop_history
            ]
            False -> model.pop_history
          }

          // Check for extinction (all animals dead)
          let finished = stats.herbivores == 0 && stats.predators == 0
          let events = case finished {
            True -> [Extinction(tick: new_tick), ..events]
            False -> events
          }

          // Sample runtime metrics on extinction
          let #(final_beam, final_mem, final_rq, final_elapsed) = case
            finished
          {
            True -> {
              let m = runtime_stats.sample()
              #(
                m.beam_processes,
                m.total_memory_bytes,
                m.run_queue,
                m.monotonic_ms - model.start_time_ms,
              )
            }
            False -> #(
              model.final_beam_processes,
              model.final_total_memory_bytes,
              model.final_run_queue,
              model.final_wall_clock_ms,
            )
          }

          let model =
            WorldModel(
              ..model,
              grid:,
              stats:,
              total_births:,
              total_deaths:,
              events:,
              pop_history:,
              peak_plants:,
              peak_herbivores:,
              peak_predators:,
              finished:,
              had_first_death: model.had_first_death || deaths > 0,
              had_first_birth: model.had_first_birth || births > 0,
              had_first_herb_born: model.had_first_herb_born
                || births > 0
                && stats.herbivores > model.prev_herbivores,
              had_first_pred_born: model.had_first_pred_born
                || births > 0
                && stats.predators > model.prev_predators,
              prev_herbivores: stats.herbivores,
              prev_predators: stats.predators,
              final_beam_processes: final_beam,
              final_total_memory_bytes: final_mem,
              final_run_queue: final_rq,
              final_wall_clock_ms: final_elapsed,
            )

          let model = case finished {
            // Stop the tick timer on extinction
            True -> {
              let _ = cancel_timer(model.tick_timer)
              model
            }
            False -> schedule_tick(model)
          }

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
      let initial_sample =
        PopSample(
          tick: 0,
          plants: stats.plants,
          herbivores: stats.herbivores,
          predators: stats.predators,
        )
      let model =
        WorldModel(
          ..model,
          grid:,
          stats:,
          paused: False,
          total_births: 0,
          total_deaths: 0,
          finished: False,
          events: [],
          pop_history: [initial_sample],
          peak_plants: stats.plants,
          peak_herbivores: stats.herbivores,
          peak_predators: stats.predators,
          had_first_death: False,
          had_first_birth: False,
          had_first_herb_born: False,
          had_first_pred_born: False,
          prev_herbivores: stats.herbivores,
          prev_predators: stats.predators,
          start_time_ms: runtime_stats.monotonic_ms(),
          final_beam_processes: 0,
          final_total_memory_bytes: 0,
          final_run_queue: 0,
          final_wall_clock_ms: 0,
          peak_llm_queue: 0,
          peak_llm_in_flight: 0,
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
      let peak_llm_queue = int.max(model.peak_llm_queue, llm_queue)
      let peak_llm_in_flight = int.max(model.peak_llm_in_flight, llm_in_flight)
      let model =
        WorldModel(
          ..model,
          llm_calls:,
          llm_errors:,
          llm_queue:,
          llm_in_flight:,
          peak_llm_queue:,
          peak_llm_in_flight:,
        )
      actor.continue(model)
    }

    SetScheduler(scheduler, model_name:) -> {
      let model =
        WorldModel(..model, scheduler: Some(scheduler), llm_model: model_name)
      actor.continue(model)
    }

    SetLLMConcurrency(n) -> {
      case model.scheduler {
        Some(scheduler) -> process.send(scheduler, SetConcurrency(n))
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

/// Record notable events for this tick.
fn record_events(
  model: WorldModel,
  stats: Stats,
  births: Int,
  deaths: Int,
) -> List(Event) {
  let tick = stats.tick
  let events = model.events

  // First death
  let events = case !model.had_first_death && deaths > 0 {
    True -> [FirstDeath(tick:), ..events]
    False -> events
  }

  // First birth
  let events = case !model.had_first_birth && births > 0 {
    True -> [FirstBirth(tick:), ..events]
    False -> events
  }

  // First herbivore born
  let events = case
    !model.had_first_herb_born && stats.herbivores > model.prev_herbivores
  {
    True -> [FirstHerbBorn(tick:), ..events]
    False -> events
  }

  // First predator born
  let events = case
    !model.had_first_pred_born && stats.predators > model.prev_predators
  {
    True -> [FirstPredBorn(tick:), ..events]
    False -> events
  }

  // Peak population milestones (only record if it's a new peak)
  let events = case stats.plants > model.peak_plants {
    True -> [
      PeakPopulation(tick:, label: "plants", count: stats.plants),
      ..events
    ]
    False -> events
  }
  let events = case stats.herbivores > model.peak_herbivores {
    True -> [
      PeakPopulation(tick:, label: "herbivores", count: stats.herbivores),
      ..events
    ]
    False -> events
  }
  let events = case stats.predators > model.peak_predators {
    True -> [
      PeakPopulation(tick:, label: "predators", count: stats.predators),
      ..events
    ]
    False -> events
  }

  // Last herbivore died
  let events = case model.prev_herbivores > 0 && stats.herbivores == 0 {
    True -> [LastHerbDied(tick:), ..events]
    False -> events
  }

  // Last predator died
  let events = case model.prev_predators > 0 && stats.predators == 0 {
    True -> [LastPredDied(tick:), ..events]
    False -> events
  }

  events
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
    finished: model.finished,
    events: model.events,
    pop_history: model.pop_history,
    peak_plants: model.peak_plants,
    peak_herbivores: model.peak_herbivores,
    peak_predators: model.peak_predators,
    beam_processes: model.final_beam_processes,
    total_memory_bytes: model.final_total_memory_bytes,
    run_queue: model.final_run_queue,
    wall_clock_elapsed_ms: model.final_wall_clock_ms,
    peak_llm_queue: model.peak_llm_queue,
    peak_llm_in_flight: model.peak_llm_in_flight,
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
