import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleeunit
import jscheam/schema
import pig/tool
import pig/tool/execution
import pig_protocol/message
import pig_protocol/tool_definition

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

pub fn canonical_dispatch_binds_context_to_registry_selected_call_test() {
  let registry = tool.new_registry() |> tool.register(context_tool())
  let call =
    message.ToolCall(id: "original-id", name: "context", arguments_json: "{}")
  let assert Ok(result) = tool.execute_tool(registry, call)
  assert json.to_string(result)
    == "{\"id\":\"original-id\",\"name\":\"context\"}"
}

// --- Batch Validation ---

pub fn empty_batch_is_valid_test() {
  assert execution.validate_tool_calls([]) == Ok(Nil)
}

pub fn error_message_renders_batch_errors_test() {
  assert tool.error_message(tool.InvalidToolCallBatch(tool.EmptyToolCallId(3)))
    == "invalid tool call batch: empty call ID at index 3"
  assert tool.error_message(
      tool.InvalidToolCallBatch(tool.DuplicateToolCallId("duplicate")),
    )
    == "invalid tool call batch: duplicate call ID \"duplicate\""
}

pub fn empty_id_batch_rejects_all_calls_test() {
  let calls = [
    message.ToolCall(id: "first", name: "echo", arguments_json: "{}"),
    message.ToolCall(id: "", name: "echo", arguments_json: "{}"),
  ]
  assert execution.validate_tool_calls(calls) == Error(tool.EmptyToolCallId(1))
}

pub fn duplicate_id_batch_rejects_all_calls_test() {
  let calls = [
    message.ToolCall(id: "same", name: "echo", arguments_json: "{}"),
    message.ToolCall(id: "same", name: "other", arguments_json: "{}"),
  ]
  assert execution.validate_tool_calls(calls)
    == Error(tool.DuplicateToolCallId("same"))
}

pub fn batch_validation_uses_first_invalidity_left_to_right_test() {
  let empty_before_duplicate = [
    message.ToolCall(id: "same", name: "echo", arguments_json: "{}"),
    message.ToolCall(id: "", name: "echo", arguments_json: "{}"),
    message.ToolCall(id: "same", name: "echo", arguments_json: "{}"),
  ]
  let duplicate_before_empty = [
    message.ToolCall(id: "same", name: "echo", arguments_json: "{}"),
    message.ToolCall(id: "same", name: "echo", arguments_json: "{}"),
    message.ToolCall(id: "", name: "echo", arguments_json: "{}"),
  ]
  assert execution.validate_tool_calls(empty_before_duplicate)
    == Error(tool.EmptyToolCallId(1))
  assert execution.validate_tool_calls(duplicate_before_empty)
    == Error(tool.DuplicateToolCallId("same"))
}

// --- Execute Unknown Tool ---

pub fn execute_unknown_tool_returns_error_test() {
  let registry = tool.new_registry()
  let call =
    message.ToolCall(id: "call_3", name: "no_such_tool", arguments_json: "{}")
  let assert Error(err) = execution.execute_tool(registry, call)
  tool.error_message(err) == "unknown tool \"no_such_tool\""
}

pub fn execute_unknown_tool_in_nonempty_registry_test() {
  let registry =
    tool.new_registry()
    |> tool.register(echo_tool())
  let call =
    message.ToolCall(id: "call_4", name: "missing", arguments_json: "{}")
  let assert Error(err) = execution.execute_tool(registry, call)
  tool.error_message(err) == "unknown tool \"missing\""
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
  tool.error_message(err) == "invalid JSON arguments for tool \"echo\""
}

pub fn execute_tool_empty_string_args_returns_error_test() {
  let registry =
    tool.new_registry()
    |> tool.register(echo_tool())
  let call = message.ToolCall(id: "call_6", name: "echo", arguments_json: "")
  let assert Error(err) = execution.execute_tool(registry, call)
  tool.error_message(err) == "invalid JSON arguments for tool \"echo\""
}

// --- Handler Returns Error ---

pub fn execute_tool_handler_error_propagates_test() {
  let registry =
    tool.new_registry()
    |> tool.register(failing_tool())
  let call = message.ToolCall(id: "call_7", name: "fail", arguments_json: "{}")
  let assert Error(err) = execution.execute_tool(registry, call)
  tool.error_message(err) == "something went wrong"
}

// --- Helpers ---

fn echo_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "echo",
      description: "Echo tool",
      parameters: schema.object([]),
    ),
    handler: fn(_, args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
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
    handler: fn(_, args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
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

fn context_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "context",
      description: "Returns the execution context",
      parameters: schema.object([]),
    ),
    handler: fn(context, _) {
      Ok(
        json.object([
          #("id", json.string(tool.call_id(context))),
          #("name", json.string(tool.tool_name(context))),
        ]),
      )
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
    handler: fn(_, _args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
      Error(tool.ToolError(message: "something went wrong"))
    },
  )
}
