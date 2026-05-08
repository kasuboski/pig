//// Intent types for the ecosystem simulation.
//// Each agent (herbivore/predator) has a current Intent that the
//// deterministic simulation follows every tick.

import gleam/int
import gleam/string

/// Cardinal directions for movement intents.
pub type Direction {
  North
  South
  East
  West
}

/// An agent's current intention. The deterministic sim follows these.
pub type Intent {
  Move(Direction)
  Eat
  Reproduce
  Rest
  Wander
}

/// Convert an intent to a short string for display/debugging.
pub fn to_string(intent: Intent) -> String {
  case intent {
    Move(North) -> "N"
    Move(South) -> "S"
    Move(East) -> "E"
    Move(West) -> "W"
    Eat -> "eat"
    Reproduce -> "repro"
    Rest -> "rest"
    Wander -> "wander"
  }
}

/// Generate a random intent. Used in Phase 1 (no LLM).
/// Uses a simple random integer to pick from the options.
pub fn random() -> Intent {
  let roll = int.random(8)
  case roll {
    0 -> Move(North)
    1 -> Move(South)
    2 -> Move(East)
    3 -> Move(West)
    4 -> Eat
    5 -> Reproduce
    6 -> Rest
    _ -> Wander
  }
}

/// Parse a one-word LLM response into an Intent.
/// Any unrecognized response defaults to Wander.
pub fn parse(word: String) -> Intent {
  case string.lowercase(string.trim(word)) {
    "north" | "n" | "up" -> Move(North)
    "south" | "s" | "down" -> Move(South)
    "east" | "e" | "right" -> Move(East)
    "west" | "w" | "left" -> Move(West)
    "eat" | "feed" | "hunt" | "graze" | "consume" | "forage" -> Eat
    "reproduce" | "breed" | "mate" | "spawn" -> Reproduce
    "rest" | "sleep" | "wait" | "stay" | "idle" | "live" -> Rest
    "wander" | "move" | "walk" | "roam" | "explore" | "travel" | "go" -> Wander
    _ -> Wander
  }
}
