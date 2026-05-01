//// Tests for new SessionEvent variants.
////
//// Tests structural equality and construction of new variants without crashing.

import gleeunit
import gleeunit/should
import pig/ai/message.{ToolCall}
import pig/obs/events.{
  HookActionDetail,
  InferenceStarted,
  ToolStarted,
  ToolBlocked,
  HookActed,
  BeforeToolCall,
  AfterToolCall,
  BeforeInference,
  AfterInference,
  OnError,
  OnComplete,
  OnSessionStart,
  OnSessionShutdown,
  tool_blocked_name,
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

  // Verify structural equality
  BeforeToolCall
  |> should.equal(BeforeToolCall)

  AfterToolCall
  |> should.equal(AfterToolCall)

  BeforeInference
  |> should.equal(BeforeInference)

  AfterInference
  |> should.equal(AfterInference)

  OnError
  |> should.equal(OnError)

  OnComplete
  |> should.equal(OnComplete)

  OnSessionStart
  |> should.equal(OnSessionStart)

  OnSessionShutdown
  |> should.equal(OnSessionShutdown)

  // Verify they are NOT equal
  BeforeToolCall
  |> should.not_equal(AfterToolCall)

  OnSessionStart
  |> should.not_equal(BeforeToolCall)
}

// ── HookActionDetail Type Tests ───────────────────────────────────

pub fn hook_action_detail_constructs_test() {
  let detail = HookActionDetail(
    action_type: "modify_args",
    description: "Changed expression format",
  )

  detail.action_type
  |> should.equal("modify_args")

  detail.description
  |> should.equal("Changed expression format")

  // Verify structural equality
  let detail2 = HookActionDetail(
    action_type: "modify_args",
    description: "Changed expression format",
  )

  detail
  |> should.equal(detail2)

  // Verify different details are not equal
  let detail3 = HookActionDetail(
    action_type: "block",
    description: "Blocked for safety",
  )

  detail
  |> should.not_equal(detail3)
}

// ── InferenceStarted Variant Tests ─────────────────────────────────────

pub fn inference_started_constructs_test() {
  let event = InferenceStarted(model: "gpt-4", message_count: 3)

  event.model
  |> should.equal("gpt-4")

  event.message_count
  |> should.equal(3)

  // Verify structural equality
  let event2 = InferenceStarted(model: "gpt-4", message_count: 3)
  event
  |> should.equal(event2)

  // Verify different events are not equal
  let event3 = InferenceStarted(model: "gpt-3.5", message_count: 3)
  event
  |> should.not_equal(event3)
}

// ── ToolStarted Variant Tests ─────────────────────────────────────────

pub fn tool_started_constructs_test() {
  let tool_call = ToolCall(
    id: "call_123",
    name: "calculator",
    arguments_json: "{\"expr\":\"2+2\"}",
  )

  let event = ToolStarted(tool_call: tool_call)

  event.tool_call.id
  |> should.equal("call_123")

  event.tool_call.name
  |> should.equal("calculator")

  event.tool_call.arguments_json
  |> should.equal("{\"expr\":\"2+2\"}")

  // Verify structural equality
  let tool_call2 = ToolCall(
    id: "call_123",
    name: "calculator",
    arguments_json: "{\"expr\":\"2+2\"}",
  )
  let event2 = ToolStarted(tool_call: tool_call2)
  event
  |> should.equal(event2)

  // Verify different events are not equal
  let tool_call3 = ToolCall(
    id: "call_456",
    name: "weather",
    arguments_json: "{\"city\":\"NYC\"}",
  )
  let event3 = ToolStarted(tool_call: tool_call3)
  event
  |> should.not_equal(event3)
}

// ── ToolBlocked Variant Tests ─────────────────────────────────────────

pub fn tool_blocked_constructs_test() {
  let tool_call = ToolCall(
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

  event.tool_call.id
  |> should.equal("call_123")

  event.tool_call.name
  |> should.equal("calculator")

  event.hook_name
  |> should.equal("safety_guard")

  event.reason
  |> should.equal("Expression contains disallowed characters")

  // Verify structural equality
  let tool_call2 = ToolCall(
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
  event
  |> should.equal(event2)

  // Verify different events are not equal
  let event3 =
    ToolBlocked(
      tool_call: tool_call,
      hook_name: "safety_guard",
      reason: "Different reason",
    )
  event
  |> should.not_equal(event3)
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

  event.hook_name
  |> should.equal("safety_guard")

  event.hook_point
  |> should.equal(BeforeToolCall)

  event.action.action_type
  |> should.equal("modify_args")

  event.action.description
  |> should.equal("Changed expression format")

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
  event
  |> should.equal(event2)

  // Verify different events are not equal
  let event3 =
    HookActed(
      hook_name: "safety_guard",
      hook_point: AfterToolCall,
      action: action,
    )
  event
  |> should.not_equal(event3)
}

// ── tool_blocked_name Function Tests ───────────────────────────────────

pub fn tool_blocked_name_returns_correct_value_test() {
  let result = tool_blocked_name()

  result
  |> should.equal(["pig", "tool", "blocked"])
}
