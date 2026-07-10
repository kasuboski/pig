//// Tool registry contract tests.
////
//// Only tests that document behavioral contracts, not dict round-trips.
//// Construction, handler calling, equality: all compiler-enforced or tested
//// via execution_test and agent scenarios.

import gleam/dynamic
import gleam/json
import gleeunit
import jscheam/schema
import pig/ai/tool_definition
import pig/tool

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Registry Contract ────────────────────────────────────────────

/// Registering the same name twice keeps the second registration.
/// This is a contract decision (overwrite, not error).
pub fn register_overwrite_test() {
  let td_v1 =
    tool_definition.ToolDefinition(
      name: "get_weather",
      description: "v1",
      parameters: schema.object([]),
    )
  let td_v2 =
    tool_definition.ToolDefinition(
      name: "get_weather",
      description: "v2",
      parameters: schema.object([]),
    )
  let handler = fn(_args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
    Ok(json.null())
  }
  let registry =
    tool.new_registry()
    |> tool.register(tool.Tool(definition: td_v1, handler: handler))
    |> tool.register(tool.Tool(definition: td_v2, handler: handler))
  let assert Ok(found) = tool.lookup(registry, "get_weather")
  assert found.definition.description == "v2"
}

/// Looking up a nonexistent tool returns Error — no crash.
pub fn lookup_nonexistent_returns_error_test() {
  let registry = tool.new_registry()
  assert tool.lookup(registry, "no_such_tool") == Error(Nil)
}
