import gleam/dict.{type Dict}
import gleam/list
import scale_test/intent.{type Intent}

pub type Position =
  #(Int, Int)

pub type OrganismType {
  Plant
  Herbivore
  Predator
}

pub type Organism {
  Organism(
    otype: OrganismType,
    pos: Position,
    energy: Int,
    intent: Intent,
    age: Int,
    thinking: Bool,
  )
}

pub type Grid =
  Dict(Position, Organism)

const grid_size = 100

/// Create a new empty grid
pub fn new() -> Grid {
  dict.new()
}

/// Get an organism at a position
pub fn get(grid: Grid, pos: Position) -> Result(Organism, Nil) {
  dict.get(grid, pos)
}

/// Insert an organism into the grid
/// Returns the same grid if the cell is already occupied
pub fn insert(grid: Grid, organism: Organism) -> Grid {
  case dict.has_key(grid, organism.pos) {
    True -> grid
    False -> dict.insert(grid, organism.pos, organism)
  }
}

/// Remove an organism at a position
pub fn remove(grid: Grid, pos: Position) -> Grid {
  dict.delete(grid, pos)
}

/// Move an organism from one position to another
/// No-op if the destination is occupied or source is empty
pub fn move(grid: Grid, from_pos: Position, to_pos: Position) -> Grid {
  case dict.get(grid, from_pos) {
    Ok(organism) -> {
      case dict.has_key(grid, to_pos) {
        True -> grid
        False -> {
          let updated_organism = Organism(..organism, pos: to_pos)
          grid
          |> dict.delete(from_pos)
          |> dict.insert(to_pos, updated_organism)
        }
      }
    }
    Error(Nil) -> grid
  }
}

/// Get all organisms in the grid
pub fn organisms(grid: Grid) -> List(Organism) {
  dict.values(grid)
}

/// Check if a position is within bounds (0..99 for both x and y)
pub fn in_bounds(pos: Position) -> Bool {
  let #(x, y) = pos
  x >= 0 && x < grid_size && y >= 0 && y < grid_size
}

/// Get adjacent positions (4 cardinal neighbors, in-bounds only)
pub fn adjacent_positions(pos: Position) -> List(Position) {
  let #(x, y) = pos
  let neighbors = [#(x, y - 1), #(x, y + 1), #(x - 1, y), #(x + 1, y)]
  list.filter(neighbors, in_bounds)
}

/// Wrap a position around the edges of the 100×100 grid using modulo
pub fn wrap_position(pos: Position) -> Position {
  let #(x, y) = pos
  #(
    case x < 0 {
      True -> grid_size + x % grid_size
      False -> x % grid_size
    },
    case y < 0 {
      True -> grid_size + y % grid_size
      False -> y % grid_size
    },
  )
}

/// Get the number of organisms in the grid
pub fn size(grid: Grid) -> Int {
  dict.size(grid)
}

/// Count organisms by type
/// Returns #(plants, herbivores, predators)
pub fn count_by_type(grid: Grid) -> #(Int, Int, Int) {
  dict.values(grid)
  |> list.fold(from: #(0, 0, 0), with: fn(acc, organism) {
    let #(plants, herbivores, predators) = acc
    case organism.otype {
      Plant -> #(plants + 1, herbivores, predators)
      Herbivore -> #(plants, herbivores + 1, predators)
      Predator -> #(plants, herbivores, predators + 1)
    }
  })
}

/// Get empty adjacent positions
pub fn empty_neighbors(grid: Grid, pos: Position) -> List(Position) {
  pos
  |> adjacent_positions()
  |> list.filter(fn(adj_pos) { !dict.has_key(grid, adj_pos) })
}

/// Convert grid to list of organisms
pub fn to_list(grid: Grid) -> List(Organism) {
  dict.values(grid)
}
