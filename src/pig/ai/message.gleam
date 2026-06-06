import gleam/option.{type Option}
import pig/ai/stop_reason.{type StopReason}

/// A tool call requested by the assistant.
pub type ToolCall {
  ToolCall(id: String, name: String, arguments_json: String)
}

/// A thinking/reasoning block from the assistant.
pub type Thinking {
  Thinking(content: String)
}

/// Unified message type for all conversation participants.
pub type Message {
  User(content: String)
  System(content: String)
  Assistant(
    content: String,
    tool_calls: List(ToolCall),
    thinking: Option(Thinking),
    stop_reason: Option(StopReason),
  )
  Tool(tool_call_id: String, content: String)
}

/// The role of a message participant.
pub type Role {
  UserRole
  AssistantRole
  SystemRole
  ToolRole
}

/// Get the role of a message.
pub fn role(msg: Message) -> Role {
  case msg {
    User(_) -> UserRole
    System(_) -> SystemRole
    Assistant(_, _, _, _) -> AssistantRole
    Tool(_, _) -> ToolRole
  }
}
