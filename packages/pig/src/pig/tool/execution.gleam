//// Pure tool execution.
////
//// Looks up a tool in the registry, parses the tool call's JSON arguments
//// into `dynamic.Dynamic`, and calls the handler. Returns structured errors
//// for unknown tools, malformed JSON, or handler failures. Never crashes.

import gleam/dynamic/decode
import gleam/json
import pig_protocol/message.{type ToolCall}
import pig/tool.{type ToolError, type ToolRegistry}

/// Execute a tool call against the registry.
///
/// Parses `arguments_json` into `dynamic.Dynamic` before passing to the handler.
/// Returns:
/// - `Ok(json.Json)` on successful execution
/// - `Error(ToolError)` for unknown tools, malformed args, or handler errors
pub fn execute_tool(
  registry: ToolRegistry,
  call: ToolCall,
) -> Result(json.Json, ToolError) {
  case tool.lookup(registry, call.name) {
    Ok(t) -> {
      case json.parse(from: call.arguments_json, using: decode.dynamic) {
        Ok(args) -> t.handler(args)
        Error(_) ->
          Error(tool.ToolError(
            message: "invalid JSON arguments for tool \"" <> call.name <> "\"",
          ))
      }
    }
    Error(Nil) ->
      Error(tool.ToolError(message: "unknown tool \"" <> call.name <> "\""))
  }
}
