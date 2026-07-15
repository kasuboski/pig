//// Librarian tool tests (Task 7.2).
////
//// Tests that the librarian tool produces a working `Tool` value
//// that can read skill content on demand.

import gleam/json
import gleam/string
import gleeunit
import pig/skill
import pig/skill/librarian
import pig/tool
import pig/tool/execution
import pig_protocol/message

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Tool construction ────────────────────────────────────────────

/// librarian_tool produces a Tool with name "read_skill".
pub fn librarian_tool_has_correct_name_test() {
  let skills = []
  let t = librarian.librarian_tool(skills)
  assert t.definition.name == "read_skill"
}

/// librarian_tool has a non-empty description.
pub fn librarian_tool_has_description_test() {
  let skills = []
  let t = librarian.librarian_tool(skills)
  assert t.definition.description != ""
}

// ── Execution ────────────────────────────────────────────────────

/// Executing read_skill with a known skill name returns its content.
pub fn read_known_skill_test() {
  let skills = [
    skill.Skill(
      name: "gleam-expert",
      description: "Expert Gleam advice.",
      path: "./test_data/skills/gleam-expert",
      files: [],
    ),
  ]
  let t = librarian.librarian_tool(skills)
  let arguments_json =
    json.to_string(json.object([#("name", json.string("gleam-expert"))]))
  let result =
    execution.execute_tool(
      tool.new_registry() |> tool.register(t),
      message.ToolCall(id: "test", name: "read_skill", arguments_json:),
    )
  let assert Ok(json_val) = result
  let content = json.to_string(json_val)
  assert string.contains(content, "Gleam Expert")
}

/// Executing read_skill with an unknown name returns an error.
pub fn read_unknown_skill_returns_error_test() {
  let skills = [
    skill.Skill(
      name: "gleam-expert",
      description: "Expert Gleam advice.",
      path: "./test_data/skills/gleam-expert",
      files: [],
    ),
  ]
  let t = librarian.librarian_tool(skills)
  let arguments_json =
    json.to_string(json.object([#("name", json.string("nonexistent"))]))
  let result =
    execution.execute_tool(
      tool.new_registry() |> tool.register(t),
      message.ToolCall(id: "test", name: "read_skill", arguments_json:),
    )
  let assert Error(tool.ToolError(message: msg)) = result
  assert string.contains(msg, "nonexistent")
}
