//// Librarian tool for skill content reading.
////
//// Creates a `Tool` that lets the agent read skill content on demand
//// by skill name. The tool handler reads SKILL.md from disk and
//// returns it as a JSON string.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import jscheam/schema
import pig_protocol/tool_definition
import pig/skill
import pig/tool
import simplifile

/// Create a librarian tool from a list of loaded skills.
///
/// The tool is named `read_skill` and accepts `{"name": "<skill-name>"}`.
/// It reads the SKILL.md content from disk and returns it as JSON.
pub fn librarian_tool(skills: List(skill.Skill)) -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "read_skill",
      description: "Read the full content of a skill by name. "
        <> "Returns the SKILL.md content for the requested skill.",
      parameters: schema.object([schema.prop("name", schema.string())]),
    ),
    handler: fn(args: dynamic.Dynamic) {
      case
        decode.run(args, decode.field("name", decode.string, decode.success))
      {
        Ok(name) -> {
          case find_skill(skills, name) {
            Ok(s) -> read_skill_content(s)
            Error(Nil) ->
              Error(tool.ToolError(
                message: "Unknown skill \""
                <> name
                <> "\". Available: "
                <> available_names(skills),
              ))
          }
        }
        Error(_) ->
          Error(tool.ToolError(
            message: "Invalid arguments: expected {\"name\": \"<skill-name>\"}",
          ))
      }
    },
  )
}

fn find_skill(
  skills: List(skill.Skill),
  name: String,
) -> Result(skill.Skill, Nil) {
  list.find(skills, fn(s) { s.name == name })
}

fn read_skill_content(s: skill.Skill) -> Result(json.Json, tool.ToolError) {
  let path = s.path <> "/SKILL.md"
  case simplifile.read(from: path) {
    Ok(content) -> Ok(json.string(content))
    Error(_) ->
      Error(tool.ToolError(message: "Failed to read skill file: " <> path))
  }
}

fn available_names(skills: List(skill.Skill)) -> String {
  skills
  |> list.map(fn(s) { s.name })
  |> string.join(", ")
}
