//// Integration-level scenario tests using the pure `update` function.
////
//// These replace the old `core.run_to_completion` tests with pure folds.
//// No OTP processes, no dispatcher, no mocks beyond sample data.
////
//// Pure value-in/value-out. The entire agent loop becomes a fold over messages.

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

import gleam/list
import gleam/string

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Helpers ──────────────────────────────────────────────────────

/// Build initial state for scenario tests.
fn initial_state(tools: List(tool.Tool)) -> state.AgentState {
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let provider = fn(_msgs, _tools) {
    Ok(provider.from_message(message.Assistant("unused", [], None)))
  }
  state.config(provider)
  |> state.with_tools(registry)
  |> state.new()
}

fn initial_state_with_max(
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

/// Apply an update and simulate runtime by feeding pre-canned responses.
/// This is the pure fold that replaces `core.run_to_completion`.
fn run_scenario(
  st: state.AgentState,
  user_prompt: String,
  provider_responses: List(message.Message),
) -> #(state.AgentState, step_result.StepResult(msg.AgentMsg)) {
  // Step 1: Apply UserPrompt
  let result = update.update(st, msg.UserPrompt(user_prompt))
  // Step 2: Extract the CallProvider effect, feed the first response
  let assert step_result.Continue(state: st1, effects: effs1) = result
  let assert [effect.CallProvider(..)] = effs1
  // Feed the first provider response
  let resp1 = list.first(provider_responses)
  case resp1 {
    Ok(msg) -> {
      let result2 = update.update(st1, msg.ProviderResponded(Ok(msg)))
      // Continue folding through the remaining responses
      fold_responses(st1, result2, list.drop(provider_responses, 1))
    }
    Error(_) -> #(st1, result)
  }
}

/// Fold through provider responses, handling tool call chains.
fn fold_responses(
  st: state.AgentState,
  current_result: step_result.StepResult(msg.AgentMsg),
  remaining_responses: List(message.Message),
) -> #(state.AgentState, step_result.StepResult(msg.AgentMsg)) {
  case current_result {
    step_result.Done(..) -> #(st, current_result)
    step_result.Failed(..) -> #(st, current_result)
    step_result.Continue(state: new_st, effects: effs) -> {
      // Process effects — there should be exactly one
      case effs {
        [effect.ExecuteTools(calls:, on_results: _)] -> {
          // Simulate tool execution: produce results for each call
          let tool_results =
            list.map(calls, fn(call) {
              // Produce a mock result based on tool name
              case call.name {
                "echo" -> #(
                  call,
                  Ok(json.object([#("echo", json.string("mocked"))])),
                )
                "boom" -> #(
                  call,
                  Error(tool.ToolError(message: "tool exploded")),
                )
                _ -> #(call, Error(tool.ToolError(message: "unknown tool")))
              }
            })
          let result2 = update.update(new_st, msg.ToolResults(tool_results))
          // After tool results, we get a Continue with CallProvider
          case result2 {
            step_result.Continue(state: st2, effects: [effect.CallProvider(..)]) -> {
              // Feed next provider response
              case list.first(remaining_responses) {
                Ok(resp) -> {
                  let result3 =
                    update.update(st2, msg.ProviderResponded(Ok(resp)))
                  fold_responses(
                    st2,
                    result3,
                    list.drop(remaining_responses, 1),
                  )
                }
                Error(_) -> #(st2, result2)
              }
            }
            other -> #(new_st, other)
          }
        }
        [effect.CallProvider(..)] -> {
          // This shouldn't happen in normal flow after UserPrompt,
          // but handle it anyway
          case list.first(remaining_responses) {
            Ok(resp) -> {
              let result2 =
                update.update(new_st, msg.ProviderResponded(Ok(resp)))
              fold_responses(new_st, result2, list.drop(remaining_responses, 1))
            }
            Error(_) -> #(new_st, current_result)
          }
        }
        _ -> #(new_st, current_result)
      }
    }
  }
}

// ── Scenario Tests ───────────────────────────────────────────────

/// Scenario 1: Provider returns text immediately.
pub fn scenario_simple_response_test() {
  let final = message.Assistant("4", [], None)
  let #(_st, result) = run_scenario(initial_state([]), "What is 2+2?", [final])
  let assert step_result.Done(state: _, message: msg) = result
  msg |> should.equal(final)
}

/// Scenario 2: Provider calls one tool, then returns text.
pub fn scenario_single_tool_call_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"test\"}",
    )
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("done!", [], None)
  let #(_, result) =
    run_scenario(initial_state([echo_tool()]), "use echo", [tool_resp, final])
  let assert step_result.Done(state: _, message: msg) = result
  msg |> should.equal(final)
}

/// Scenario 3: Provider calls 3 tools at once, then returns text.
pub fn scenario_multi_tool_call_test() {
  let tc1 =
    message.ToolCall(id: "a", name: "echo", arguments_json: "{\"msg\":\"x\"}")
  let tc2 =
    message.ToolCall(id: "b", name: "echo", arguments_json: "{\"msg\":\"y\"}")
  let tc3 =
    message.ToolCall(id: "c", name: "echo", arguments_json: "{\"msg\":\"z\"}")
  let tool_resp = message.Assistant("", [tc1, tc2, tc3], None)
  let final = message.Assistant("all done!", [], None)
  let #(_, result) =
    run_scenario(initial_state([echo_tool()]), "multi call", [tool_resp, final])
  let assert step_result.Done(state: _, message: msg) = result
  msg |> should.equal(final)
}

/// Scenario 4: Chained tool calls.
pub fn scenario_chained_tool_calls_test() {
  let tc1 =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"first\"}",
    )
  let tc2 =
    message.ToolCall(
      id: "c2",
      name: "echo",
      arguments_json: "{\"msg\":\"second\"}",
    )
  let resp1 = message.Assistant("", [tc1], None)
  let resp2 = message.Assistant("", [tc2], None)
  let final = message.Assistant("chained complete!", [], None)
  let #(_, result) =
    run_scenario(initial_state([echo_tool()]), "chain", [resp1, resp2, final])
  let assert step_result.Done(state: _, message: msg) = result
  msg |> should.equal(final)
}

/// Scenario 5: Provider error terminates the loop with Failed.
pub fn scenario_provider_error_test() {
  let st = initial_state([])
  let result = update.update(st, msg.UserPrompt("hello"))
  let assert step_result.Continue(state: st1, effects: _) = result
  let result2 =
    update.update(
      st1,
      msg.ProviderResponded(Error(error.ApiError("provider failed"))),
    )
  let assert step_result.Failed(state: _, error: e) = result2
  e |> should.equal(error.ApiError("provider failed"))
}

/// Scenario 6: Circuit breaker — infinite tool-call loop terminates.
pub fn scenario_max_iterations_circuit_breaker_test() {
  let tc =
    message.ToolCall(
      id: "loop",
      name: "echo",
      arguments_json: "{\"msg\":\"x\"}",
    )
  let looping = message.Assistant("", [tc], None)
  // Start with max_iterations = 2
  let st = initial_state_with_max([echo_tool()], 2)
  // Step 1: UserPrompt → Continue
  let result = update.update(st, msg.UserPrompt("loop"))
  let assert step_result.Continue(state: st1, effects: _) = result
  // Step 2: ProviderResponded with tool calls → Continue with ExecuteTools
  let result2 = update.update(st1, msg.ProviderResponded(Ok(looping)))
  let assert step_result.Continue(state: st2, effects: _) = result2
  // Step 3: ToolResults → Continue (iterations now 1)
  let tool_results = [
    #(tc, Ok(json.object([#("echo", json.string("x"))]))),
  ]
  let result3 = update.update(st2, msg.ToolResults(tool_results))
  let assert step_result.Continue(state: st3, effects: _) = result3
  st3.iterations |> should.equal(1)
  // Step 4: Provider responds with tool calls again
  let result4 = update.update(st3, msg.ProviderResponded(Ok(looping)))
  let assert step_result.Continue(state: st4, effects: _) = result4
  // Step 5: ToolResults again (iterations now 2) — exceeds max
  let result5 = update.update(st4, msg.ToolResults(tool_results))
  let assert step_result.Failed(state: _, error: e) = result5
  case e {
    error.ApiError(message:) ->
      string.contains(message, "exceeded maximum iterations")
      |> should.be_true()
    _ -> should.be_true(False)
  }
}

/// Scenario 7: Tool error does NOT kill the loop — LLM sees error and adapts.
pub fn scenario_tool_error_recovery_test() {
  let tc = message.ToolCall(id: "c1", name: "boom", arguments_json: "{}")
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("recovered!", [], None)
  // Use a custom fold for error tool
  let st = initial_state([failing_tool()])
  let result = update.update(st, msg.UserPrompt("try boom"))
  let assert step_result.Continue(state: st1, effects: _) = result
  let result2 = update.update(st1, msg.ProviderResponded(Ok(tool_resp)))
  let assert step_result.Continue(state: st2, effects: effs) = result2
  let assert [effect.ExecuteTools(calls: _, ..)] = effs
  // Produce error result for the tool
  let tool_results = [
    #(tc, Error(tool.ToolError(message: "tool exploded"))),
  ]
  let result3 = update.update(st2, msg.ToolResults(tool_results))
  let assert step_result.Continue(state: st3, effects: _) = result3
  // History should contain the error message
  let history = state.history(st3)
  let assert Ok(message.Tool(content:, ..)) = list.last(history)
  content |> should.equal("Tool error: tool exploded")
  // Feed the final response
  let result4 = update.update(st3, msg.ProviderResponded(Ok(final)))
  let assert step_result.Done(state: _, message: msg) = result4
  msg |> should.equal(final)
}

// ── Tool helpers ─────────────────────────────────────────────────

fn echo_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "echo",
      description: "Echoes back",
      parameters: schema.object([]),
    ),
    handler: fn(_) { Error(tool.ToolError(message: "unused")) },
  )
}

fn failing_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "boom",
      description: "Always fails",
      parameters: schema.object([]),
    ),
    handler: fn(_) { Error(tool.ToolError(message: "tool exploded")) },
  )
}
