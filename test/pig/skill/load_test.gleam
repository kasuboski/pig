//// Skill loading and parsing tests (Task 7.1).
////
//// Fixture-driven boundary tests per TESTING_STRATEGY.
//// Tests exercise `pig/skill.load` against real files in test_data/skills/.

import gleam/list
import gleam/string
import gleeunit
import pig/skill

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Happy path ──────────────────────────────────────────────────

/// Loading a valid skill directory returns Ok with correct fields.
pub fn load_valid_skill_test() {
  let assert Ok(s) = skill.load("./test_data/skills/valid-skill")
  s.name == "valid-skill"
  && s.description == "A valid skill for testing purposes."
  && s.path == "./test_data/skills/valid-skill"
}

/// A valid skill with references lists supplementary files (excluding SKILL.md).
pub fn load_valid_skill_lists_files_test() {
  let assert Ok(s) = skill.load("./test_data/skills/valid-skill")
  let has_ref =
    s.files
    |> list.any(fn(f) { string.contains(f, "references/example.md") })
  has_ref
}

/// Loading an empty-skill (frontmatter only, no body) returns Ok.
pub fn load_empty_skill_test() {
  let assert Ok(s) = skill.load("./test_data/skills/empty-skill")
  s.name == "empty-skill"
  && s.description == "An empty skill with minimal content."
}

// ── Error paths ─────────────────────────────────────────────────

/// Loading a directory without SKILL.md returns Error.
pub fn load_missing_skill_md_test() {
  let result = skill.load("./test_data/skills/missing-skill-md")
  result == Error(skill.SkillNotFound)
}

/// Loading a nonexistent directory returns Error.
pub fn load_nonexistent_dir_test() {
  let result = skill.load("./test_data/skills/no-such-dir")
  result == Error(skill.SkillNotFound)
}

/// SKILL.md with no frontmatter at all returns Error (no name/description).
pub fn load_no_frontmatter_test() {
  let result = skill.load("./test_data/skills/no-frontmatter")
  result == Error(skill.InvalidFrontmatter)
}

/// SKILL.md with frontmatter but missing description returns Error.
pub fn load_missing_description_test() {
  let result = skill.load("./test_data/skills/missing-description")
  result == Error(skill.InvalidFrontmatter)
}

// ── System fragment ─────────────────────────────────────────────

/// skill_to_system_fragment produces text containing name and description.
pub fn system_fragment_contains_name_and_description_test() {
  let s =
    skill.Skill(
      name: "my-skill",
      description: "Does cool stuff.",
      path: "/some/path",
      files: [],
    )
  let fragment = skill.skill_to_system_fragment(s)
  string.contains(fragment, "my-skill")
  && string.contains(fragment, "Does cool stuff.")
}

// ── Frontmatter parsing (pure) ──────────────────────────────────

/// parse_frontmatter extracts name and description from valid YAML.
pub fn parse_frontmatter_valid_test() {
  let raw =
    "---\nname: hello\ndescription: A greeting.\n---\n\n# Hello\nBody here."
  let assert Ok(result) = skill.parse_frontmatter(raw)
  result.name == "hello"
  && result.description == "A greeting."
  && result.body == "\n# Hello\nBody here."
}

/// parse_frontmatter returns Error for missing closing delimiter.
pub fn parse_frontmatter_no_closing_delim_test() {
  let raw = "---\nname: hello\ndescription: A greeting.\n\n# No closing"
  let result = skill.parse_frontmatter(raw)
  result == Error(skill.InvalidFrontmatter)
}

/// parse_frontmatter returns Error when name is missing.
pub fn parse_frontmatter_missing_name_test() {
  let raw = "---\ndescription: No name field.\n---\n\nBody"
  let result = skill.parse_frontmatter(raw)
  result == Error(skill.InvalidFrontmatter)
}

/// parse_frontmatter returns Error when description is missing.
pub fn parse_frontmatter_missing_description_test() {
  let raw = "---\nname: no-desc\n---\n\nBody"
  let result = skill.parse_frontmatter(raw)
  result == Error(skill.InvalidFrontmatter)
}

/// parse_frontmatter returns Error for empty string.
pub fn parse_frontmatter_empty_test() {
  let result = skill.parse_frontmatter("")
  result == Error(skill.InvalidFrontmatter)
}
