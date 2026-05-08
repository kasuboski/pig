//// Pure simulation tick logic for the ecosystem.
//// Takes a Grid and returns a new Grid plus metadata.

import gleam/dict
import gleam/int
import gleam/list
import scale_test/grid.{
  Organism, type Grid, type Organism, type OrganismType, type Position, Herbivore,
  Plant, Predator, adjacent_positions, empty_neighbors, get, insert, move,
  new, organisms, remove, wrap_position,
}
import scale_test/intent.{
  Eat, East, Move, North, Reproduce, Rest, South, Wander, West,
  type Direction, random,
}

/// Result of a single simulation tick.
pub type TickResult {
  TickResult(
    grid: Grid,
    rethinks: List(Position),
    births: Int,
    deaths: Int,
  )
}

/// Internal accumulator for execute_intents.
type IntentAcc {
  IntentAcc(grid: Grid, blocked: List(Position), births: Int)
}

/// Run one full simulation tick.
pub fn tick(grid: Grid) -> TickResult {
  let IntentAcc(grid: grid_after_intents, blocked: blocked_positions, births: intent_births) =
    execute_intents(grid)
  let #(grid_after_decay, dead_count) = energy_decay(grid_after_intents)
  let grid_after_growth = plant_growth(grid_after_decay)
  let rethinks = determine_rethinks(grid_after_growth, blocked_positions)

  TickResult(
    grid: grid_after_growth,
    rethinks:,
    births: intent_births,
    deaths: dead_count,
  )
}

/// Create an initial population on the grid.
pub fn populate(plant_count: Int, herb_count: Int, pred_count: Int) -> Grid {
  let grid = new()
  let grid = populate_type(grid, Plant, plant_count)
  let grid = populate_type(grid, Herbivore, herb_count)
  populate_type(grid, Predator, pred_count)
}

fn populate_type(grid: Grid, otype: OrganismType, count: Int) -> Grid {
  int.range(from: 0, to: count, with: grid, run: fn(acc, _i) {
    let pos = random_position()
    case dict.has_key(acc, pos) {
      True -> acc
      False -> {
        let energy = case otype {
          Plant -> 20
          Herbivore -> 25
          Predator -> 30
        }
        let organism = Organism(
          otype:,
          pos:,
          energy:,
          intent: random(),
          age: 0,
          thinking: False,
        )
        dict.insert(acc, pos, organism)
      }
    }
  })
}

fn random_position() -> Position {
  #(int.random(100), int.random(100))
}

// --- Step 1: Execute intents ---

fn execute_intents(grid: Grid) -> IntentAcc {
  let all_organisms = organisms(grid)
  list.fold(
    all_organisms,
    IntentAcc(grid:, blocked: [], births: 0),
    fn(acc, organism) {
      // Ghost resurrection guard: skip if this organism has been removed
      // from the grid (e.g. eaten by a predator earlier in this same fold).
      case dict.get(acc.grid, organism.pos) {
        Ok(current) if current == organism -> {
          let #(new_g, was_blocked, births) =
            execute_intent(acc.grid, organism, acc.births)
          let new_blocked = case was_blocked {
            True -> [organism.pos, ..acc.blocked]
            False -> acc.blocked
          }
          IntentAcc(grid: new_g, blocked: new_blocked, births:)
        }
        _ -> acc
      }
    },
  )
}

fn execute_intent(
  grid: Grid,
  organism: Organism,
  births: Int,
) -> #(Grid, Bool, Int) {
  case organism.otype {
    Plant -> #(grid, False, births)
    _ -> execute_agent_intent(grid, organism, births)
  }
}

fn execute_agent_intent(
  grid: Grid,
  organism: Organism,
  births: Int,
) -> #(Grid, Bool, Int) {
  case organism.intent {
    Move(dir) -> {
      let target = wrap_position(direction_offset(organism.pos, dir))
      case dict.has_key(grid, target) {
        True -> #(grid, True, births)
        False -> #(move(grid, organism.pos, target), False, births)
      }
    }
    Eat -> {
      let #(g, blocked) = execute_eat(grid, organism)
      #(g, blocked, births)
    }
    Reproduce -> {
      let #(g, blocked, new_births) = execute_reproduce(grid, organism, births)
      #(g, blocked, new_births)
    }
    Rest -> {
      let healed = Organism(..organism, energy: organism.energy + 1)
      let g = dict.insert(grid, organism.pos, healed)
      #(g, False, births)
    }
    Wander -> {
      let dir = random_direction()
      let target = wrap_position(direction_offset(organism.pos, dir))
      case dict.has_key(grid, target) {
        True -> #(grid, True, births)
        False -> #(move(grid, organism.pos, target), False, births)
      }
    }
  }
}

fn execute_eat(grid: Grid, organism: Organism) -> #(Grid, Bool) {
  let neighbors = adjacent_positions(organism.pos)
  let food_type = case organism.otype {
    Herbivore -> Plant
    Predator -> Herbivore
    Plant -> Plant
  }

  case find_food(grid, neighbors, food_type) {
    Ok(food_pos) -> {
      let grid = remove(grid, food_pos)
      let energy_gain = case organism.otype {
        Herbivore -> 10
        Predator -> 20
        Plant -> 0
      }
      let fed = Organism(
        ..organism,
        energy: organism.energy + energy_gain,
        intent: random(),
      )
      let grid = dict.insert(grid, organism.pos, fed)
      #(grid, False)
    }
    Error(Nil) -> #(grid, True)
  }
}

fn find_food(
  grid: Grid,
  positions: List(Position),
  food_type: OrganismType,
) -> Result(Position, Nil) {
  list.find(positions, fn(pos) {
    case get(grid, pos) {
      Ok(o) -> o.otype == food_type
      Error(Nil) -> False
    }
  })
}

fn execute_reproduce(
  grid: Grid,
  organism: Organism,
  births: Int,
) -> #(Grid, Bool, Int) {
  case organism.energy > 15 {
    False -> #(grid, True, births)
    True -> {
      let empties = empty_neighbors(grid, organism.pos)
      case empties {
        [] -> #(grid, True, births)
        [spot, ..] -> {
          let parent = Organism(..organism, energy: organism.energy - 10)
          let grid = dict.insert(grid, parent.pos, parent)
          let offspring = Organism(
            otype: organism.otype,
            pos: spot,
            energy: 10,
            intent: random(),
            age: 0,
            thinking: False,
          )
          let grid = insert(grid, offspring)
          #(grid, False, births + 1)
        }
      }
    }
  }
}

fn direction_offset(pos: Position, dir: Direction) -> Position {
  let #(x, y) = pos
  case dir {
    North -> #(x, y - 1)
    South -> #(x, y + 1)
    East -> #(x + 1, y)
    West -> #(x - 1, y)
  }
}

fn random_direction() -> Direction {
  case int.random(4) {
    0 -> North
    1 -> South
    2 -> East
    _ -> West
  }
}

// --- Step 2: Energy decay ---

fn energy_decay(grid: Grid) -> #(Grid, Int) {
  dict.fold(
    grid,
    #(new(), 0),
    fn(acc, _pos, organism) {
      let #(g, dead) = acc
      let new_energy = organism.energy - 1
      case new_energy <= 0 {
        True -> #(g, dead + 1)
        False -> {
          let aged = Organism(
            ..organism,
            energy: new_energy,
            age: organism.age + 1,
          )
          #(dict.insert(g, organism.pos, aged), dead)
        }
      }
    },
  )
}

// --- Step 3: Plant growth ---

fn plant_growth(grid: Grid) -> Grid {
  // Each existing plant has a chance to spread to an adjacent empty cell
  let grid = dict.fold(grid, grid, fn(g, pos, organism) {
    case organism.otype {
      Plant -> {
        case int.random(100) < 5 {
          True -> {
            let empties = empty_neighbors(g, pos)
            case empties {
              [] -> g
              [spot, ..] -> {
                let new_plant = Organism(
                  otype: Plant,
                  pos: spot,
                  energy: 20,
                  intent: random(),
                  age: 0,
                  thinking: False,
                )
                insert(g, new_plant)
              }
            }
          }
          False -> g
        }
      }
      _ -> g
    }
  })

  // Spontaneous sprouting in random empty cells
  let extra = int.random(3)
  int.range(from: 0, to: extra, with: grid, run: fn(g, _i) {
    let pos = random_position()
    case dict.has_key(g, pos) {
      True -> g
      False -> {
        let sprout = Organism(
          otype: Plant,
          pos:,
          energy: 20,
          intent: random(),
          age: 0,
          thinking: False,
        )
        dict.insert(g, pos, sprout)
      }
    }
  })
}

// --- Step 5: Determine re-thinks ---

fn determine_rethinks(grid: Grid, blocked: List(Position)) ->
    List(Position) {
  dict.fold(
    grid,
    [],
    fn(acc, pos, organism) {
      case organism.otype {
        Plant -> acc
        _ -> {
          let is_blocked = list.contains(blocked, pos)
          let random_rethink = int.random(100) < 2
          let interesting = has_interesting_neighbor(grid, organism)
          case is_blocked || random_rethink || interesting {
            True -> [pos, ..acc]
            False -> acc
          }
        }
      }
    },
  )
}

fn has_interesting_neighbor(grid: Grid, organism: Organism) -> Bool {
  let neighbors = adjacent_positions(organism.pos)
  list.any(neighbors, fn(pos) {
    case get(grid, pos) {
      Ok(neighbor) -> {
        case organism.otype {
          Herbivore -> neighbor.otype == Predator
          Predator -> neighbor.otype == Herbivore
          Plant -> False
        }
      }
      Error(Nil) -> False
    }
  })
}

/// Apply new random intents to organisms at given positions.
pub fn apply_random_intents(grid: Grid, positions: List(Position)) -> Grid {
  list.fold(positions, grid, fn(g, pos) {
    case get(g, pos) {
      Ok(organism) -> {
        let updated = Organism(..organism, intent: random())
        dict.insert(g, pos, updated)
      }
      Error(Nil) -> g
    }
  })
}
