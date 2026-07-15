//// Tool types and registry for the pig agent library.
////
//// A `Tool` pairs a `ToolDefinition` (schema for the LLM) with a handler
//// function. The handler receives library-owned immutable invocation context
//// and parsed `dynamic.Dynamic` arguments, and returns a `json.Json` result
//// or structured `ToolError`.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import pig_protocol/message.{type ToolCall}
import pig_protocol/tool_definition.{type ToolDefinition}

/// Immutable identity of a tool invocation.
///
/// Contexts are created from protocol tool calls by pig's canonical dispatch;
/// handlers can inspect them but cannot manufacture or alter them.
pub opaque type ToolCallContext {
  ToolCallContext(call_id: String, tool_name: String)
}

/// Return the protocol call ID for this invocation.
pub fn call_id(context: ToolCallContext) -> String {
  context.call_id
}

/// Return the requested tool name for this invocation.
pub fn tool_name(context: ToolCallContext) -> String {
  context.tool_name
}

/// Deterministic reason a tool-call batch is invalid.
pub type ToolCallBatchError {
  EmptyToolCallId(index: Int)
  DuplicateToolCallId(call_id: String)
}

/// Structured error from tool execution.
pub type ToolError {
  ToolError(message: String)
  InvalidToolCallBatch(error: ToolCallBatchError)
}

/// Render a structured tool error for tool-result messages and users.
pub fn error_message(error: ToolError) -> String {
  case error {
    ToolError(message) -> message
    InvalidToolCallBatch(EmptyToolCallId(index)) ->
      "invalid tool call batch: empty call ID at index " <> int.to_string(index)
    InvalidToolCallBatch(DuplicateToolCallId(call_id)) ->
      "invalid tool call batch: duplicate call ID \"" <> call_id <> "\""
  }
}

/// A tool pairs a definition (shown to the LLM) with a handler function.
/// The handler receives immutable call context and parsed JSON arguments.
pub type Tool {
  Tool(
    definition: ToolDefinition,
    handler: fn(ToolCallContext, Dynamic) -> Result(Json, ToolError),
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

/// Execute a protocol tool call through its registry-selected handler.
///
/// The call name selects the registered tool; that same call is decoded and
/// supplies the immutable context passed to its handler. Returns structured
/// errors for unknown tools, malformed arguments, or handler failures.
pub fn execute_tool(
  registry: ToolRegistry,
  call: ToolCall,
) -> Result(Json, ToolError) {
  case lookup(registry, call.name) {
    Ok(tool) -> {
      case json.parse(from: call.arguments_json, using: decode.dynamic) {
        Ok(arguments) ->
          tool.handler(
            ToolCallContext(call_id: call.id, tool_name: call.name),
            arguments,
          )
        Error(_) ->
          Error(ToolError(
            message: "invalid JSON arguments for tool \"" <> call.name <> "\"",
          ))
      }
    }
    Error(Nil) ->
      Error(ToolError(message: "unknown tool \"" <> call.name <> "\""))
  }
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
