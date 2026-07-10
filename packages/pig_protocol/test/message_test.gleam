//// Message contract tests.
////
//// Only tests with real logic: the `role()` mapping function.
//// Construction and equality are enforced by the Gleam compiler.
//// Parsing round-trips are tested via golden files in openai_test.

import gleam/option.{None}
import gleeunit
import pig_protocol/message

pub fn main() -> Nil {
  gleeunit.main()
}

// ── role() mapping ───────────────────────────────────────────────

pub fn role_user_test() {
  assert message.role(message.User("x")) == message.UserRole
}

pub fn role_system_test() {
  assert message.role(message.System("x")) == message.SystemRole
}

pub fn role_assistant_test() {
  assert message.role(message.Assistant("x", [], None, None))
    == message.AssistantRole
}

pub fn role_tool_test() {
  assert message.role(message.Tool(tool_call_id: "id", content: "x"))
    == message.ToolRole
}
