//// Skill loading and parsing.
////
//// A Skill is a directory on disk containing a `SKILL.md` file with
//// YAML frontmatter (name + description) and a markdown body.
////
//// Frontmatter parsing is deliberately simple: split on `---` delimiters,
//// extract `name` and `description` fields from the YAML-like block.
//// No full YAML parser needed.

import gleam/list
import gleam/string
import simplifile

/// A loaded skill with its metadata.
pub type Skill {
  Skill(
    name: String,
    description: String,
    path: String,
    files: List(String),
  )
}

/// Errors that can occur during skill loading.
pub type SkillError {
  SkillNotFound
  InvalidFrontmatter
}

/// Parsed frontmatter fields and remaining body.
pub type Frontmatter {
  Frontmatter(name: String, description: String, body: String)
}

/// Load a skill from a directory path.
///
/// Reads `SKILL.md` from the directory, parses frontmatter for name/description,
/// and lists supplementary files (everything except `SKILL.md`).
pub fn load(path: String) -> Result(Skill, SkillError) {
  let skill_md_path = path <> "/SKILL.md"
  case simplifile.read(from: skill_md_path) {
    Ok(content) -> {
      case parse_frontmatter(content) {
        Ok(fm) ->
          Ok(Skill(
            name: fm.name,
            description: fm.description,
            path:,
            files: list_files(path),
          ))
        Error(e) -> Error(e)
      }
    }
    Error(_) -> Error(SkillNotFound)
  }
}

/// Parse frontmatter from a SKILL.md content string.
///
/// Expects `---\n` at start, content between delimiters, and closing `---\n`.
/// Extracts `name:` and `description:` fields. Returns remaining body after
/// the closing delimiter.
///
/// This is a simple parser — not a full YAML parser. It handles:
/// - `key: value` lines
pub fn parse_frontmatter(raw: String) -> Result(Frontmatter, SkillError) {
  case string.split(raw, on: "\n") {
    ["---", ..rest] -> parse_lines(rest, "", "", True)
    _ -> Error(InvalidFrontmatter)
  }
}

/// Walk frontmatter lines collecting name/description accumulators.
fn parse_lines(
  lines: List(String),
  acc_name: String,
  acc_desc: String,
  in_fm: Bool,
) -> Result(Frontmatter, SkillError) {
  case lines {
    [] -> Error(InvalidFrontmatter)
    ["---", ..rest] if in_fm -> {
      let body = string.join(rest, "\n")
      case acc_name, acc_desc {
        "", _ | _, "" -> Error(InvalidFrontmatter)
        _, _ ->
          Ok(Frontmatter(
            name: string.trim(acc_name),
            description: string.trim(acc_desc),
            body:,
          ))
      }
    }
    [line, ..rest] if in_fm -> {
      let parts = string.split(line, on: ": ")
      case parts {
        [key, value] -> {
          let new_name = case key {
            "name" -> value
            _ -> acc_name
          }
          let new_desc = case key {
            "description" -> value
            _ -> acc_desc
          }
          parse_lines(rest, new_name, new_desc, True)
        }
        _ -> parse_lines(rest, acc_name, acc_desc, True)
      }
    }
    _ -> Error(InvalidFrontmatter)
  }
}

/// Generate a system prompt fragment from a skill.
///
/// Used to inject skill descriptions into the system prompt so the agent
/// knows what skills are available.
pub fn skill_to_system_fragment(skill: Skill) -> String {
  "Skill: "
  <> skill.name
  <> "\nDescription: "
  <> skill.description
  <> "\nPath: "
  <> skill.path
  <> "\n"
}

/// List supplementary files in a skill directory (excluding SKILL.md).
/// Returns relative paths from the skill directory.
fn list_files(path: String) -> List(String) {
  case simplifile.read_directory(at: path) {
    Ok(entries) ->
      entries
      |> list.filter(fn(e) { e != "SKILL.md" })
      |> list.filter(fn(e) {
        let full = path <> "/" <> e
        case simplifile.is_file(full) {
          Ok(True) -> True
          _ -> False
        }
      })
    Error(_) -> []
  }
}
