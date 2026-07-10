//// Agent message type for the sans-IO core.
////
//// Messages drive the state machine. They represent both user inputs
//// and runtime responses fed back into the core:
////
////   - `UserPrompt`       — a new prompt to process
////   - `ProviderResponded` — the LLM's response (or error)
////   - `ToolResults`       — tool execution outcomes

import gleam/json.{type Json}
import pig_protocol/error.{type AiError}
import pig_protocol/message.{type Message, type ToolCall}
import pig/tool.{type ToolError}

/// Messages that drive the agent state machine.
pub type AgentMsg {
  /// A new user prompt. Starts or continues the conversation.
  UserPrompt(String)

  /// The LLM provider's response, delivered by the runtime after
  /// executing a `CallProvider` effect.
  ProviderResponded(Result(Message, AiError))

  /// Tool execution outcomes, delivered by the runtime after
  /// executing an `ExecuteTools` effect.
  ToolResults(List(#(ToolCall, Result(Json, ToolError))))
}
