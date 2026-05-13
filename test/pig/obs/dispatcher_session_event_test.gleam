//// Tests for new SessionEvent variants.
////
//// Tests structural equality and construction of new variants without crashing.

import gleeunit
import pig/ai/message.{ToolCall}
import pig/obs/events.{
  AfterInference, AfterToolCall, BeforeInference, BeforeToolCall, HookActed,
  HookActionDetail, InferenceStarted, OnComplete, OnError, OnSessionShutdown,
  OnSessionStart, ToolBlocked, ToolStarted, tool_blocked_name,
}

pub fn main() {
  gleeunit.main()
}

// ── HookPoint Type Tests ──────────────────────────────────────────

pub fn hook_point_variants_construct_test() {
  // Verify all HookPoint variants can be constructed without crashing
  let _ = BeforeToolCall
  let _ = AfterToolCall
  let _ = BeforeInference
  let _ = AfterInference
  let _ = OnError
  let _ = OnComplete
  let _ = OnSessionStart
  let _ = OnSessionShutdown

  // Verify structural equality (enum variants are always structurally equal to themselves)
  let _ = BeforeToolCall == BeforeToolCall
  let _ = AfterToolCall == AfterToolCall
  let _ = BeforeInference == BeforeInference
  let _ = AfterInference == AfterInference
  let _ = OnError == OnError
  let _ = OnComplete == OnComplete
  let _ = OnSessionStart == OnSessionStart
  let _ = OnSessionShutdown == OnSessionShutdown

  // Verify they are NOT equal
  assert BeforeToolCall != AfterToolCall
  assert OnSessionStart != BeforeToolCall
}

// ── HookActionDetail Type Tests ───────────────────────────────────

pub fn hook_action_detail_constructs_test() {
  let detail =
    HookActionDetail(
      action_type: "modify_args",
      description: "Changed expression format",
    )

  assert detail.action_type == "modify_args"

  assert detail.description == "Changed expression format"

  // Verify structural equality
  let detail2 =
    HookActionDetail(
      action_type: "modify_args",
      description: "Changed expression format",
    )

  assert detail == detail2

  // Verify different details are not equal
  let detail3 =
    HookActionDetail(action_type: "block", description: "Blocked for safety")

  assert detail != detail3
}

// ── InferenceStarted Variant Tests ─────────────────────────────────────

pub fn inference_started_constructs_test() {
  let event = InferenceStarted(model: "gpt-4", message_count: 3)

  assert event.model == "gpt-4"

  assert event.message_count == 3

  // Verify structural equality
  let event2 = InferenceStarted(model: "gpt-4", message_count: 3)
  assert event == event2

  // Verify different events are not equal
  let event3 = InferenceStarted(model: "gpt-3.5", message_count: 3)
  assert event != event3
}

// ── ToolStarted Variant Tests ─────────────────────────────────────────

pub fn tool_started_constructs_test() {
  let tool_call =
    ToolCall(
      id: "call_123",
      name: "calculator",
      arguments_json: "{\"expr\":\"2+2\"}",
    )

  let event = ToolStarted(tool_call: tool_call)

  assert event.tool_call.id == "call_123"

  assert event.tool_call.name == "calculator"

  assert event.tool_call.arguments_json == "{\"expr\":\"2+2\"}"

  // Verify structural equality
  let tool_call2 =
    ToolCall(
      id: "call_123",
      name: "calculator",
      arguments_json: "{\"expr\":\"2+2\"}",
    )
  let event2 = ToolStarted(tool_call: tool_call2)
  assert event == event2

  // Verify different events are not equal
  let tool_call3 =
    ToolCall(
      id: "call_456",
      name: "weather",
      arguments_json: "{\"city\":\"NYC\"}",
    )
  let event3 = ToolStarted(tool_call: tool_call3)
  assert event != event3
}

// ── ToolBlocked Variant Tests ─────────────────────────────────────────

pub fn tool_blocked_constructs_test() {
  let tool_call =
    ToolCall(
      id: "call_123",
      name: "calculator",
      arguments_json: "{\"expr\":\"2+2\"}",
    )

  let event =
    ToolBlocked(
      tool_call: tool_call,
      hook_name: "safety_guard",
      reason: "Expression contains disallowed characters",
    )

  assert event.tool_call.id == "call_123"

  assert event.tool_call.name == "calculator"

  assert event.hook_name == "safety_guard"

  assert event.reason == "Expression contains disallowed characters"

  // Verify structural equality
  let tool_call2 =
    ToolCall(
      id: "call_123",
      name: "calculator",
      arguments_json: "{\"expr\":\"2+2\"}",
    )
  let event2 =
    ToolBlocked(
      tool_call: tool_call2,
      hook_name: "safety_guard",
      reason: "Expression contains disallowed characters",
    )
  assert event == event2

  // Verify different events are not equal
  let event3 =
    ToolBlocked(
      tool_call: tool_call,
      hook_name: "safety_guard",
      reason: "Different reason",
    )
  assert event != event3
}

// ── HookActed Variant Tests ───────────────────────────────────────

pub fn hook_acted_constructs_test() {
  let action =
    HookActionDetail(
      action_type: "modify_args",
      description: "Changed expression format",
    )

  let event =
    HookActed(
      hook_name: "safety_guard",
      hook_point: BeforeToolCall,
      action: action,
    )

  assert event.hook_name == "safety_guard"

  assert event.hook_point == BeforeToolCall

  assert event.action.action_type == "modify_args"

  assert event.action.description == "Changed expression format"

  // Verify structural equality
  let action2 =
    HookActionDetail(
      action_type: "modify_args",
      description: "Changed expression format",
    )
  let event2 =
    HookActed(
      hook_name: "safety_guard",
      hook_point: BeforeToolCall,
      action: action2,
    )
  assert event == event2

  // Verify different events are not equal
  let event3 =
    HookActed(
      hook_name: "safety_guard",
      hook_point: AfterToolCall,
      action: action,
    )
  assert event != event3
}

// ── tool_blocked_name Function Tests ───────────────────────────────────

pub fn tool_blocked_name_returns_correct_value_test() {
  let result = tool_blocked_name()

  assert result == ["pig", "tool", "blocked"]
}