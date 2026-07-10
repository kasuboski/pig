import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleeunit
import jscheam/schema
import pig_protocol/message
import pig_protocol/tool_definition
import pig/tool
import pig/tool/execution

pub fn main() -> Nil {
  gleeunit.main()
}

// --- Execute Known Tool ---

pub fn execute_known_tool_test() {
  let registry =
    tool.new_registry()
    |> tool.register(echo_tool())
  let call =
    message.ToolCall(
      id: "call_1",
      name: "echo",
      arguments_json: "{\"msg\": \"hello\"}",
    )
  let assert Ok(result) = execution.execute_tool(registry, call)
  json.to_string(result) == "{\"echo\":\"hello\"}"
}

pub fn execute_tool_handler_receives_dynamic_test() {
  let registry =
    tool.new_registry()
    |> tool.register(field_extractor_tool())
  let call =
    message.ToolCall(
      id: "call_2",
      name: "extract",
      arguments_json: "{\"city\": \"SF\", \"count\": 3}",
    )
  let assert Ok(result) = execution.execute_tool(registry, call)
  // Handler extracted city field from Dynamic
  json.to_string(result) == "{\"result\":\"SF\"}"
}

// --- Execute Unknown Tool ---

pub fn execute_unknown_tool_returns_error_test() {
  let registry = tool.new_registry()
  let call =
    message.ToolCall(id: "call_3", name: "no_such_tool", arguments_json: "{}")
  let assert Error(err) = execution.execute_tool(registry, call)
  err.message == "unknown tool \"no_such_tool\""
}

pub fn execute_unknown_tool_in_nonempty_registry_test() {
  let registry =
    tool.new_registry()
    |> tool.register(echo_tool())
  let call =
    message.ToolCall(id: "call_4", name: "missing", arguments_json: "{}")
  let assert Error(err) = execution.execute_tool(registry, call)
  err.message == "unknown tool \"missing\""
}

// --- Malformed JSON Args ---

pub fn execute_tool_malformed_json_returns_error_test() {
  let registry =
    tool.new_registry()
    |> tool.register(echo_tool())
  let call =
    message.ToolCall(
      id: "call_5",
      name: "echo",
      arguments_json: "not valid json {{{",
    )
  let assert Error(err) = execution.execute_tool(registry, call)
  err.message == "invalid JSON arguments for tool \"echo\""
}

pub fn execute_tool_empty_string_args_returns_error_test() {
  let registry =
    tool.new_registry()
    |> tool.register(echo_tool())
  let call = message.ToolCall(id: "call_6", name: "echo", arguments_json: "")
  let assert Error(err) = execution.execute_tool(registry, call)
  err.message == "invalid JSON arguments for tool \"echo\""
}

// --- Handler Returns Error ---

pub fn execute_tool_handler_error_propagates_test() {
  let registry =
    tool.new_registry()
    |> tool.register(failing_tool())
  let call = message.ToolCall(id: "call_7", name: "fail", arguments_json: "{}")
  let assert Error(err) = execution.execute_tool(registry, call)
  err.message == "something went wrong"
}

// --- Helpers ---

fn echo_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "echo",
      description: "Echo tool",
      parameters: schema.object([]),
    ),
    handler: fn(args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
      let assert Ok(msg) =
        decode.run(args, decode.field("msg", decode.string, decode.success))
      Ok(json.object([#("echo", json.string(msg))]))
    },
  )
}

fn field_extractor_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "extract",
      description: "Extracts city field",
      parameters: schema.object([]),
    ),
    handler: fn(args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
      case
        decode.run(args, decode.field("city", decode.string, decode.success))
      {
        Ok(city) -> Ok(json.object([#("result", json.string(city))]))
        Error(_) ->
          Error(tool.ToolError(message: "missing or invalid 'city' field"))
      }
    },
  )
}

fn failing_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "fail",
      description: "Always fails",
      parameters: schema.object([]),
    ),
    handler: fn(_args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
      Error(tool.ToolError(message: "something went wrong"))
    },
  )
}
