import pig/ai/message.{type Message}
import pig/ai/tool_definition.{type ToolDefinition}
import pig/ai/error.{type AiError}

/// A provider is a function that takes messages and tool definitions,
/// calls an LLM, and returns either an assistant message or an error.
pub type Provider =
  fn(List(Message), List(ToolDefinition)) -> Result(Message, AiError)
