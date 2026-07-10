//// Tool types and registry for the pig agent library.
////
//// A `Tool` pairs a `ToolDefinition` (schema for the LLM) with a handler
//// function. The handler receives parsed `dynamic.Dynamic` arguments and
//// returns either a `json.Json` result or a structured `ToolError`.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/list
import pig/ai/tool_definition.{type ToolDefinition}

/// Structured error from tool execution.
pub type ToolError {
  ToolError(message: String)
}

/// A tool pairs a definition (shown to the LLM) with a handler function.
/// The handler receives parsed JSON arguments as `dynamic.Dynamic` and
/// returns either a `json.Json` result or a structured `ToolError`.
pub type Tool {
  Tool(
    definition: ToolDefinition,
    handler: fn(Dynamic) -> Result(Json, ToolError),
  )
}

/// A registry of tools indexed by name.
pub type ToolRegistry {
  ToolRegistry(entries: Dict(String, Tool))
}

/// Create an empty tool registry.
pub fn new_registry() -> ToolRegistry {
  ToolRegistry(entries: dict.new())
}

/// Register a tool in the registry. If a tool with the same name already
/// exists, it is overwritten.
pub fn register(registry: ToolRegistry, tool: Tool) -> ToolRegistry {
  ToolRegistry(entries: dict.insert(
    registry.entries,
    tool.definition.name,
    tool,
  ))
}

/// Look up a tool by name. Returns `Error(Nil)` if not found.
pub fn lookup(registry: ToolRegistry, name: String) -> Result(Tool, Nil) {
  dict.get(registry.entries, name)
}

/// List all tool definitions in the registry.
pub fn list_definitions(registry: ToolRegistry) -> List(ToolDefinition) {
  registry.entries
  |> dict.values()
  |> list.map(fn(t: Tool) -> ToolDefinition { t.definition })
}

/// A tool's name and description for composing into a system prompt.
pub type ToolPrompt {
  ToolPrompt(name: String, description: String)
}

/// Extract name and description from each tool in the registry.
/// Used to auto-compose an "Available tools" section in the system prompt.
pub fn list_tool_prompts(registry: ToolRegistry) -> List(ToolPrompt) {
  registry.entries
  |> dict.values()
  |> list.map(fn(t: Tool) -> ToolPrompt {
    ToolPrompt(name: t.definition.name, description: t.definition.description)
  })
}
