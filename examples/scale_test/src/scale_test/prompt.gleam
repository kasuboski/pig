//// Prompt builder for ecosystem agents.
//// Constructs prompts for herbivore/predator agents.
//// Supports single-organism and batch (multi-organism) prompts.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import scale_test/grid.{
  type Organism, type OrganismType, Herbivore, Plant, Predator,
}
import scale_test/intent.{to_string}

/// Build a prompt string for a single agent.
pub fn build(
  organism: Organism,
  nearby: List(#(String, Option(OrganismType))),
) -> String {
  let role = case organism.otype {
    Herbivore -> "herbivore (rabbit)"
    Predator -> "predator (wolf)"
    Plant -> "plant"
  }
  let current_plan = to_string(organism.intent)
  let nearby_str = describe_nearby(nearby)
  let #(x, y) = organism.pos

  "You are a "
  <> role
  <> " at ("
  <> int.to_string(x)
  <> ","
  <> int.to_string(y)
  <> ") energy:"
  <> int.to_string(organism.energy)
  <> "/30.\n"
  <> "Nearby: "
  <> nearby_str
  <> ".\n"
  <> "Current plan: "
  <> current_plan
  <> ".\n"
  <> "Respond with ONE word: north/south/east/west/eat/reproduce/rest/wander"
}

/// Build a batch prompt for multiple organisms.
/// Returns a prompt that asks the LLM to decide for each organism,
/// one decision per line.
pub fn build_batch(
  decisions: List(#(Organism, List(#(String, Option(OrganismType))), String)),
) -> String {
  let entries =
    decisions
    |> list.index_map(fn(entry, i) {
      let #(organism, nearby, food_hint) = entry
      let role = case organism.otype {
        Herbivore -> "H"
        Predator -> "P"
        Plant -> "X"
      }
      let nearby_str = describe_nearby(nearby)
      let #(x, y) = organism.pos
      int.to_string(i + 1)
      <> ". "
      <> role
      <> " ("
      <> int.to_string(x)
      <> ","
      <> int.to_string(y)
      <> ") e="
      <> int.to_string(organism.energy)
      <> " "
      <> nearby_str
      <> case food_hint {
        "" -> ""
        hint -> " [" <> hint <> "]"
      }
    })
    |> string.join("\n")

  let count = list.length(decisions)
  "Decide the next action for each organism. "
  <> "Actions: north/south/east/west/eat/reproduce/rest/wander\n"
  <> "H=herbivore P=predator. Respond with "
  <> int.to_string(count)
  <> " words, one per line:\n\n"
  <> entries
}

/// Parse a batch response into individual action strings.
/// Expects one word per line. Returns a list of strings.
pub fn parse_batch(response: String, expected_count: Int) -> List(String) {
  let lines =
    response
    |> string.split("\n")
    |> list.map(fn(line) {
      line
      |> string.trim()
      |> string.lowercase()
    })
    |> list.filter(fn(line) { line != "" })

  case list.length(lines) == expected_count {
    True -> lines
    False -> {
      // Try splitting by whitespace as fallback (single-line responses)
      let words =
        response
        |> string.lowercase()
        |> string.split(" ")
        |> list.map(string.trim)
        |> list.filter(fn(w) { w != "" })
      case list.length(words) >= expected_count {
        True -> list.take(words, expected_count)
        False -> lines
      }
    }
  }
}

/// Describe nearby cells as "N=plant S=empty E=predator W=empty"
pub fn describe_nearby(
  nearby: List(#(String, Option(OrganismType))),
) -> String {
  case nearby {
    [] -> "nothing"
    _ ->
      nearby
      |> list.map(fn(entry) {
        let #(dir, opt_type) = entry
        case opt_type {
          Some(Plant) -> dir <> "=plant"
          Some(Herbivore) -> dir <> "=herb"
          Some(Predator) -> dir <> "=pred"
          None -> dir <> "=empty"
        }
      })
      |> string.join(" ")
  }
}
