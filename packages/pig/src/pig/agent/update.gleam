//// Pure agent state machine — the sans-IO update function.
////
//// `update(state, msg) -> StepResult(msg)` is a pure function:
//// no provider calls, no tool execution, no telemetry, no hooks.
////
//// The runtime calls this function, interprets the returned effects,
//// and feeds results back as new messages.

import gleam/json
import gleam/list
import pig/agent/effect
import pig/agent/msg.{type AgentMsg}
import pig/agent/state.{type AgentState}
import pig/agent/step_result.{type StepResult}
import pig_protocol/error.{type AiError}
import pig_protocol/message.{type Message}
import pig/tool.{type ToolError}

/// Pure state transition: given current state and a message, return
/// the next state and any effects the runtime should execute.
///
/// This is the entire agent loop logic, sans IO.
pub fn update(st: AgentState, m: AgentMsg) -> StepResult(AgentMsg) {
  case m {
    msg.UserPrompt(prompt) -> handle_user_prompt(st, prompt)
    msg.ProviderResponded(result) -> handle_provider_responded(st, result)
    msg.ToolResults(results) -> handle_tool_results(st, results)
  }
}

// ── UserPrompt ──────────────────────────────────────────────────

fn handle_user_prompt(st: AgentState, prompt: String) -> StepResult(AgentMsg) {
  let new_st = state.add_message(st, message.User(prompt))
  let msgs = state.messages_for_provider(new_st)
  let tools = state.tool_definitions(new_st)
  step_result.Continue(state: new_st, effects: [
    effect.CallProvider(messages: msgs, tools:, on_response: fn(r) {
      case r {
        Ok(ir) -> msg.ProviderResponded(Ok(ir.message))
        Error(e) -> msg.ProviderResponded(Error(e))
      }
    }),
  ])
}

// ── ProviderResponded ───────────────────────────────────────────

fn handle_provider_responded(
  st: AgentState,
  result: Result(Message, AiError),
) -> StepResult(AgentMsg) {
  case result {
    Ok(
      message.Assistant(
        content: _,
        tool_calls: calls,
        thinking: _,
        stop_reason: _,
      ) as assistant_msg,
    ) ->
      case calls {
        [] -> {
          // Text response — loop terminates
          let new_st = state.add_message(st, assistant_msg)
          step_result.Done(state: new_st, message: assistant_msg)
        }
        _ -> {
          // Tool calls — need execution
          let new_st = state.add_message(st, assistant_msg)
          step_result.Continue(state: new_st, effects: [
            effect.ExecuteTools(calls:, on_results: fn(results) {
              msg.ToolResults(results)
            }),
          ])
        }
      }
    Ok(other) -> {
      // Non-assistant message (shouldn't happen from provider, but handle gracefully)
      let new_st = state.add_message(st, other)
      step_result.Done(state: new_st, message: other)
    }
    Error(e) -> step_result.Failed(state: st, error: e)
  }
}

// ── ToolResults ──────────────────────────────────────────────────

fn handle_tool_results(
  st: AgentState,
  results: List(#(message.ToolCall, Result(json.Json, ToolError))),
) -> StepResult(AgentMsg) {
  // Convert results to Tool messages and add to history
  // Increment iterations first — mirrors the original loop which
  // increments after tool execution and checks at the top of the next iteration.
  let tool_messages =
    list.map(results, fn(pair) {
      let #(call, result) = pair
      let content = case result {
        Ok(json_val) -> json.to_string(json_val)
        Error(tool_err) -> "Tool error: " <> tool_err.message
      }
      message.Tool(tool_call_id: call.id, content:)
    })
  let new_st =
    tool_messages
    |> list.fold(st, state.add_message)
    |> state.increment_iterations()
  // Check circuit breaker after incrementing (mirrors original do_run check)
  case state.exceeded_max_iterations(new_st) {
    True ->
      step_result.Failed(
        state: new_st,
        error: state.max_iterations_error(new_st),
      )
    False -> {
      // Continue with a CallProvider effect
      let msgs = state.messages_for_provider(new_st)
      let tools = state.tool_definitions(new_st)
      step_result.Continue(state: new_st, effects: [
        effect.CallProvider(messages: msgs, tools:, on_response: fn(r) {
          case r {
            Ok(ir) -> msg.ProviderResponded(Ok(ir.message))
            Error(e) -> msg.ProviderResponded(Error(e))
          }
        }),
      ])
    }
  }
}
