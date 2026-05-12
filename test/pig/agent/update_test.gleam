//// Pure `update` function tests.
////
//// Verifies the sans-IO state machine: `update(state, msg) -> StepResult(msg)`.
//// Pure value-in/value-out. No OTP processes, no dispatcher, no mocks.
////
//// Tests cover:
//// - UserPrompt: adds message, returns Continue with CallProvider effect
//// - ProviderResponded: Done (text), Continue (tool calls), Failed (error)
//// - ToolResults: adds messages, increments iterations, Continue or Failed

import gleam/json
import gleam/option.{None}
import gleeunit
import gleeunit/should
import jscheam/schema
import pig/agent/effect
import pig/agent/msg
import pig/agent/state
import pig/agent/step_result
import pig/agent/update
import pig/ai/error
import pig/ai/message
import pig/ai/provider
import pig/ai/tool_definition
import pig/tool

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Helpers ──────────────────────────────────────────────────────

/// Build a state for update tests. No dispatcher or provider needed —
/// the sans-IO core never calls them.
fn state_for_update(tools: List(tool.Tool)) -> state.AgentState {
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  // Provider is never called by update — it's a runtime concern.
  // But we need one to construct AgentConfig.
  let provider = fn(_msgs, _tools) {
    Ok(provider.from_message(message.Assistant("unused", [], None)))
  }
  state.config(provider)
  |> state.with_tools(registry)
  |> state.new()
}

fn state_for_update_with_max(
  tools: List(tool.Tool),
  max: Int,
) -> state.AgentState {
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let provider = fn(_msgs, _tools) {
    Ok(provider.from_message(message.Assistant("unused", [], None)))
  }
  state.config(provider)
  |> state.with_tools(registry)
  |> state.with_max_iterations(max)
  |> state.new()
}

import gleam/list

// ── Task 2.1: UserPrompt ──────────────────────────────────────────

/// UserPrompt adds User message to history.
pub fn user_prompt_adds_user_message_to_history_test() {
  let st = state_for_update([])
  let result = update.update(st, msg.UserPrompt("hello"))
  let assert step_result.Continue(state: new_st, effects: _) = result
  // History should contain the User message
  let history = state.history(new_st)
  list.last(history) |> should.equal(Ok(message.User("hello")))
}

/// UserPrompt returns Continue with a CallProvider effect.
pub fn user_prompt_returns_continue_with_call_provider_test() {
  let st = state_for_update([])
  let result = update.update(st, msg.UserPrompt("hello"))
  let assert step_result.Continue(state: _, effects: effs) = result
  // Should have exactly one CallProvider effect
  let call_provider_effs =
    list.filter(effs, fn(e) {
      case e {
        effect.CallProvider(..) -> True
        _ -> False
      }
    })
  list.length(call_provider_effs) |> should.equal(1)
}

/// CallProvider effect's messages include the prompt.
pub fn user_prompt_call_provider_includes_prompt_test() {
  let st = state_for_update([])
  let result = update.update(st, msg.UserPrompt("hello"))
  let assert step_result.Continue(state: _, effects: effs) = result
  let assert [effect.CallProvider(messages: msgs, ..)] = effs
  // Messages should contain the user prompt
  list.any(msgs, fn(m) {
    case m {
      message.User("hello") -> True
      _ -> False
    }
  })
  |> should.be_true()
}

/// CallProvider effect's tools match the state's tool definitions.
pub fn user_prompt_call_provider_includes_tools_test() {
  let td =
    tool_definition.ToolDefinition(
      name: "echo",
      description: "echo tool",
      parameters: schema.object([]),
    )
  let t =
    tool.Tool(definition: td, handler: fn(_) {
      Error(tool.ToolError(message: "unused"))
    })
  let st = state_for_update([t])
  let result = update.update(st, msg.UserPrompt("hello"))
  let assert step_result.Continue(state: _, effects: effs) = result
  let assert [effect.CallProvider(tools: tool_defs, ..)] = effs
  list.length(tool_defs) |> should.equal(1)
  let assert [td2] = tool_defs
  td2.name |> should.equal("echo")
}

/// System prompt is prepended to messages in the effect when configured.
pub fn user_prompt_system_prompt_prepended_test() {
  let provider = fn(_msgs, _tools) {
    Ok(provider.from_message(message.Assistant("x", [], None)))
  }
  let st =
    state.config(provider)
    |> state.with_system_prompt("you are a helper")
    |> state.new()
  let result = update.update(st, msg.UserPrompt("hello"))
  let assert step_result.Continue(state: _, effects: effs) = result
  let assert [effect.CallProvider(messages: msgs, ..)] = effs
  // First message should be the system prompt
  list.first(msgs) |> should.equal(Ok(message.System("you are a helper")))
}

// ── Task 2.2: ProviderResponded ──────────────────────────────────

/// ProviderResponded(Ok(text_message)) → Done with that message in history.
pub fn provider_responded_text_returns_done_test() {
  let st = state_for_update([])
  let resp = message.Assistant("hello!", [], None)
  let result = update.update(st, msg.ProviderResponded(Ok(resp)))
  let assert step_result.Done(state: new_st, message: msg_out) = result
  msg_out |> should.equal(resp)
  // History should contain the assistant message
  let history = state.history(new_st)
  list.last(history) |> should.equal(Ok(resp))
}

/// ProviderResponded(Ok(tool_call_message)) → Continue with ExecuteTools effect.
pub fn provider_responded_tool_calls_returns_continue_test() {
  let tc = message.ToolCall(id: "c1", name: "echo", arguments_json: "{}")
  let resp = message.Assistant("", [tc], None)
  let st = state_for_update([])
  let result = update.update(st, msg.ProviderResponded(Ok(resp)))
  let assert step_result.Continue(state: _, effects: effs) = result
  // Should have exactly one ExecuteTools effect
  let exec_effs =
    list.filter(effs, fn(e) {
      case e {
        effect.ExecuteTools(..) -> True
        _ -> False
      }
    })
  list.length(exec_effs) |> should.equal(1)
}

/// ProviderResponded(Ok(tool_call_message)) with empty tool_calls → Done.
pub fn provider_responded_empty_tool_calls_returns_done_test() {
  let resp = message.Assistant("", [], None)
  let st = state_for_update([])
  let result = update.update(st, msg.ProviderResponded(Ok(resp)))
  let assert step_result.Done(state: _, message: _) = result
}

/// ProviderResponded(Error(e)) → Failed.
pub fn provider_responded_error_returns_failed_test() {
  let st = state_for_update([])
  let err = error.ApiError("provider failed")
  let result = update.update(st, msg.ProviderResponded(Error(err)))
  let assert step_result.Failed(state: _, error: e) = result
  e |> should.equal(error.ApiError("provider failed"))
}

/// ProviderResponded(Ok(tool_call_message)) puts assistant message in history.
pub fn provider_responded_tool_calls_records_assistant_test() {
  let tc = message.ToolCall(id: "c1", name: "echo", arguments_json: "{}")
  let resp = message.Assistant("", [tc], None)
  let st = state_for_update([])
  let result = update.update(st, msg.ProviderResponded(Ok(resp)))
  let assert step_result.Continue(state: new_st, effects: _) = result
  let history = state.history(new_st)
  list.last(history) |> should.equal(Ok(resp))
}

// ── Task 2.3: ToolResults ────────────────────────────────────────

/// ToolResults adds Tool messages to history.
pub fn tool_results_adds_tool_messages_test() {
  let tc = message.ToolCall(id: "c1", name: "echo", arguments_json: "{}")
  let results = [
    #(tc, Ok(json.object([#("echo", json.string("hi"))]))),
  ]
  let st = state_for_update([])
  let result = update.update(st, msg.ToolResults(results))
  let assert step_result.Continue(state: new_st, effects: _) = result
  let history = state.history(new_st)
  list.last(history)
  |> should.equal(
    Ok(message.Tool(tool_call_id: "c1", content: "{\"echo\":\"hi\"}")),
  )
}

/// ToolResults increments iterations.
pub fn tool_results_increments_iterations_test() {
  let tc = message.ToolCall(id: "c1", name: "echo", arguments_json: "{}")
  let results = [
    #(tc, Ok(json.object([#("echo", json.string("hi"))]))),
  ]
  let st = state_for_update([])
  let result = update.update(st, msg.ToolResults(results))
  let assert step_result.Continue(state: new_st, effects: _) = result
  new_st.iterations |> should.equal(1)
}

/// ToolResults returns Continue with CallProvider effect.
pub fn tool_results_returns_continue_with_call_provider_test() {
  let tc = message.ToolCall(id: "c1", name: "echo", arguments_json: "{}")
  let results = [
    #(tc, Ok(json.object([#("echo", json.string("hi"))]))),
  ]
  let st = state_for_update([])
  let result = update.update(st, msg.ToolResults(results))
  let assert step_result.Continue(state: _, effects: effs) = result
  let call_provider_effs =
    list.filter(effs, fn(e) {
      case e {
        effect.CallProvider(..) -> True
        _ -> False
      }
    })
  list.length(call_provider_effs) |> should.equal(1)
}

/// When exceeded_max_iterations, ToolResults returns Failed.
pub fn tool_results_max_iterations_returns_failed_test() {
  let tc = message.ToolCall(id: "c1", name: "echo", arguments_json: "{}")
  let results = [
    #(tc, Ok(json.object([#("echo", json.string("hi"))]))),
  ]
  // max_iterations = 1 means after first tool result (iterations becomes 1) we exceed
  let st = state_for_update_with_max([], 1)
  let result = update.update(st, msg.ToolResults(results))
  let assert step_result.Failed(state: _, error: e) = result
  case e {
    error.ApiError(message:) ->
      message
      |> string.contains("exceeded maximum iterations")
      |> should.be_true()
    _ -> should.be_true(False)
  }
}

/// Tool error results are recorded in history correctly.
pub fn tool_results_error_recorded_in_history_test() {
  let tc = message.ToolCall(id: "c1", name: "boom", arguments_json: "{}")
  let results = [
    #(tc, Error(tool.ToolError(message: "tool exploded"))),
  ]
  let st = state_for_update([])
  let result = update.update(st, msg.ToolResults(results))
  let assert step_result.Continue(state: new_st, effects: _) = result
  let history = state.history(new_st)
  let assert Ok(message.Tool(content:, ..)) = list.last(history)
  content |> should.equal("Tool error: tool exploded")
}

import gleam/string
