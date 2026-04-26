//// Pure agent core loop — the state machine.
////
//// Three operations:
////   `step(state)`           — call provider, branch on response
////   `execute_tools_and_advance(state, calls)` — run tools, update history
////   `run_to_completion(state)` — loop until final answer or error
////
//// Telemetry events are emitted as fire-and-forget side effects via
//// `pig/obs/events`. They do not affect the return values.

import gleam/json
import gleam/list
import pig/agent/state as state
import pig/ai/error.{type AiError}
import pig/ai/message.{type Message, type ToolCall}
import pig/obs/events
import pig/tool/execution

/// Result of a single step in the agent loop.
pub type StepResult {
  /// Provider returned a text response — loop terminates.
  Complete(Message)
  /// Provider returned tool calls — they need executing.
  NeedsToolExecution(tool_calls: List(ToolCall), state: state.AgentState)
  /// Provider returned an error.
  StepError(AiError)
}

/// Execute one step: call the provider and branch on the response.
///
/// Emits `InferenceStart` before the call and `InferenceStop` or
/// `InferenceException` after, with duration measurement.
pub fn step(st: state.AgentState) -> StepResult {
  let defs = state.tool_definitions(st)
  let msgs = state.messages_for_provider(st)
  let msg_count = list.length(msgs)
  let model = st.config.model

  events.emit(events.InferenceStart(model:, message_count: msg_count))
  let start_time = events.system_time()

  let result = case st.config.provider(msgs, defs) {
    Ok(msg) -> {
      let updated = state.add_message(st, msg)
      let duration = events.system_time() - start_time
      events.emit(events.InferenceStop(
        model:,
        message_count: msg_count,
        duration_ms: duration,
      ))
      case msg {
        message.Assistant(content: _, tool_calls: calls, thinking: _) ->
          case calls {
            [] -> Complete(msg)
            _ -> NeedsToolExecution(tool_calls: calls, state: updated)
          }
        _ -> Complete(msg)
      }
    }
    Error(e) -> {
      events.emit(events.InferenceException(
        model:,
        message_count: msg_count,
      ))
      StepError(e)
    }
  }
  result
}

/// Execute tool calls against the registry and append results to history.
///
/// Emits `ToolStart` and `ToolStop` for each tool call.
/// Errors are caught and turned into Tool messages — the LLM adapts.
pub fn execute_tools_and_advance(
  st: state.AgentState,
  calls: List(ToolCall),
) -> state.AgentState {
  let tool_messages =
    list.map(calls, fn(call) {
      events.emit(events.ToolStart(
        tool_name: call.name,
        tool_call_id: call.id,
      ))
      let start_time = events.system_time()
      let result = execution.execute_tool(st.config.tools, call)
      let duration = events.system_time() - start_time
      events.emit(events.ToolStop(
        tool_name: call.name,
        tool_call_id: call.id,
        duration_ms: duration,
      ))
      case result {
        Ok(json_result) ->
          message.Tool(
            tool_call_id: call.id,
            content: json.to_string(json_result),
          )
        Error(tool_err) ->
          message.Tool(
            tool_call_id: call.id,
            content: "Tool error: " <> tool_err.message,
          )
      }
    })
  list.fold(tool_messages, st, state.add_message)
}

/// Run the agent loop to completion.
///
/// Calls `step` repeatedly. On `NeedsToolExecution`, executes tools and
/// recurses. On `Complete`, returns the final message. On `StepError`,
/// propagates the error.
///
/// Circuit breaker: terminates with `ApiError` if `max_iterations` is exceeded.
pub fn run_to_completion(st: state.AgentState) -> Result(Message, AiError) {
  do_run(st)
}

fn do_run(st: state.AgentState) -> Result(Message, AiError) {
  case state.exceeded_max_iterations(st) {
    True -> Error(state.max_iterations_error(st))
    False ->
      case step(st) {
        Complete(msg) -> Ok(msg)
        StepError(e) -> Error(e)
        NeedsToolExecution(calls, updated_state) -> {
          let advanced =
            updated_state
            |> state.increment_iterations()
            |> execute_tools_and_advance(calls)
          do_run(advanced)
        }
      }
  }
}
