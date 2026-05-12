//// Effect types for the sans-IO agent core.
////
//// Effects are declarations of intent — the core describes what it wants
//// done, and a runtime interprets these effects against the real world.
////
//// Two effects cover the entire agent loop:
////   `CallProvider`  — send messages to the LLM
////   `ExecuteTools`  — run tool calls
////
//// The `on_response` / `on_results` callbacks wrap results into the
//// core's message type, closing the loop without the core knowing
//// how the effects were executed.

import gleam/json.{type Json}
import pig/ai/error.{type AiError}
import pig/ai/message.{type Message, type ToolCall}
import pig/ai/provider.{type InferenceResult}
import pig/ai/tool_definition.{type ToolDefinition}
import pig/tool.{type ToolError}

/// An effect request from the pure core. The runtime interprets these.
pub type Effect(msg) {
  /// Send messages and tool definitions to the LLM provider.
  /// The runtime calls the provider function, then feeds the response
  /// back via the `on_response` callback.
  CallProvider(
    messages: List(Message),
    tools: List(ToolDefinition),
    on_response: fn(Result(InferenceResult, AiError)) -> msg,
  )

  /// Execute a list of tool calls. The runtime runs each tool (possibly
  /// in parallel), then feeds all results back via the `on_results` callback.
  ExecuteTools(
    calls: List(ToolCall),
    on_results: fn(List(#(ToolCall, Result(Json, ToolError)))) -> msg,
  )
}
