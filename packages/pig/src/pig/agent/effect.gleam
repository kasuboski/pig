//// Effect types for the sans-IO agent core.
////
//// Effects are declarations of intent — the core describes what it wants
//// done, and a runtime interprets these effects against the real world.
////
//// Two effects cover the entire agent loop:
////   `CallProvider`  — send messages to the LLM
////   `ExecuteTools`  — run tool calls

import pig_protocol/message.{type Message, type ToolCall}
import pig_protocol/tool_definition.{type ToolDefinition}

/// An effect request from the pure core. The runtime interprets these.
pub type Effect {
  /// Send messages and tool definitions to the LLM provider.
  CallProvider(messages: List(Message), tools: List(ToolDefinition))

  /// Execute a list of tool calls. The runtime feeds the results back as an
  /// `AgentMsg.ToolResults` message.
  ExecuteTools(calls: List(ToolCall))
}
