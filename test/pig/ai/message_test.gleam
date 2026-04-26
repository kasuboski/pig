import gleeunit
import pig/ai/message
import gleam/option.{None, Some}

pub fn main() -> Nil {
  gleeunit.main()
}

// --- Construction Tests ---

pub fn user_message_test() {
  let message.User(content:) = message.User("hello")
  content == "hello"
}

pub fn system_message_test() {
  let message.System(content:) = message.System("you are a helpful assistant")
  content == "you are a helpful assistant"
}

pub fn assistant_text_only_test() {
  let msg = message.Assistant("Hi there!", [], None)
  msg.content == "Hi there!" && msg.tool_calls == [] && msg.thinking == None
}

pub fn assistant_with_tool_calls_test() {
  let tc =
    message.ToolCall(
      id: "call_123",
      name: "get_weather",
      arguments_json: "{\"city\":\"SF\"}",
    )
  let msg = message.Assistant("", [tc], None)
  msg.tool_calls == [tc]
}

pub fn assistant_with_thinking_test() {
  let think = message.Thinking("hmm let me think")
  let msg = message.Assistant("answer", [], Some(think))
  msg.thinking == Some(think)
}

pub fn tool_result_message_test() {
  let msg = message.Tool(tool_call_id: "call_456", content: "{\"temp\": 72}")
  msg.tool_call_id == "call_456" && msg.content == "{\"temp\": 72}"
}

// --- Equality Tests ---

pub fn tool_call_equality_test() {
  let tc1 = message.ToolCall(id: "1", name: "foo", arguments_json: "{}")
  let tc2 = message.ToolCall(id: "1", name: "foo", arguments_json: "{}")
  tc1 == tc2
}

// --- Role Accessor Tests ---

pub fn role_user_test() {
  message.role(message.User("x")) == message.UserRole
}

pub fn role_system_test() {
  message.role(message.System("x")) == message.SystemRole
}

pub fn role_assistant_test() {
  message.role(message.Assistant("x", [], None)) == message.AssistantRole
}

pub fn role_tool_test() {
  message.role(message.Tool(tool_call_id: "id", content: "x"))
    == message.ToolRole
}
