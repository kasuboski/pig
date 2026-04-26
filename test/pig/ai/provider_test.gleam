import gleeunit
import pig/ai/message
import pig/ai/tool_definition
import pig/ai/error
import pig/ai/provider.{type Provider}
import gleam/option.{None}

pub fn main() -> Nil {
  gleeunit.main()
}

// A trivial stub provider that always returns a fixed assistant message
fn stub_provider(
  _messages: List(message.Message),
  _tools: List(tool_definition.ToolDefinition),
) -> Result(message.Message, error.AiError) {
  Ok(message.Assistant("stub response", [], None))
}

// A stub that always fails
fn failing_provider(
  _messages: List(message.Message),
  _tools: List(tool_definition.ToolDefinition),
) -> Result(message.Message, error.AiError) {
  Error(error.ApiError("nope"))
}

// --- Tests ---

pub fn stub_provider_returns_ok_test() {
  let result = stub_provider([], [])
  let assert Ok(msg) = result
  let assert message.Assistant(
    content: "stub response",
    tool_calls: [],
    thinking: None,
  ) = msg
  True
}

pub fn failing_provider_returns_error_test() {
  failing_provider([], []) == Error(error.ApiError("nope"))
}

pub fn provider_with_messages_test() {
  let messages = [
    message.System("you are helpful"),
    message.User("hello"),
  ]
  let result = stub_provider(messages, [])
  let assert Ok(_) = result
  True
}

pub fn provider_with_tools_test() {
  let tools = [
    tool_definition.ToolDefinition(
      name: "calc",
      description: "does math",
      parameters: "{}",
    ),
  ]
  let result = stub_provider([], tools)
  let assert Ok(_) = result
  True
}

pub fn provider_type_is_callable_test() {
  let my_provider: Provider = stub_provider
  let result = my_provider([], [])
  let assert Ok(msg) = result
  let assert message.Assistant(content:, tool_calls:, thinking:) = msg
  content == "stub response" && tool_calls == [] && thinking == None
}
