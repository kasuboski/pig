//// Pure agent core loop — the state machine.
////
//// Three operations:
////   `step(state)`           — call provider, branch on response
////   `execute_tools_and_advance(state, calls)` — run tools, update history
////   `run_to_completion(state)` — loop until final answer or error
////
//// Telemetry events are emitted as fire-and-forget side effects via
//// `pig/obs/events`. They do not affect the return values.

import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import pig/agent/state as state
import pig/ai/error.{type AiError, ApiError, InvalidResponse, RateLimited, Timeout}
import pig/ai/message.{type Message, type ToolCall}
import pig/obs/dispatcher
import pig/obs/emit
import pig/obs/events
import pig/tool/execution

/// Convert an AiError to a string for error_type telemetry.
fn error_to_string(err: AiError) -> String {
  case err {
    ApiError(_) -> "ApiError"
    RateLimited -> "RateLimited"
    Timeout -> "Timeout"
    InvalidResponse(_) -> "InvalidResponse"
  }
}

// ── Emission Helpers ───────────────────────────────────────────────

// ── Dispatcher Resolution ───────────────────────────────────────────

/// Get the dispatcher subject from the agent state.
/// If dispatcher is None but dispatcher_name is Some, resolve the name to a subject.
fn get_dispatcher(st: state.AgentState) -> option.Option(process.Subject(dispatcher.DispatcherMessage)) {
  case st.config.dispatcher {
    option.Some(disp) -> option.Some(disp)
    option.None -> {
      case st.config.dispatcher_name {
        option.Some(name) -> option.Some(process.named_subject(name))
        option.None -> option.None
      }
    }
  }
}

// ── Emission Helpers ───────────────────────────────────────────────

/// Emit InferenceStarted event.
fn emit_inference_start(st: state.AgentState, model: String, count: Int) -> Nil {
  case get_dispatcher(st) {
    option.Some(disp) -> emit.to_dispatcher(disp, events.InferenceStarted(model:, message_count: count))
    option.None -> Nil
  }
}

/// Emit InferenceCompleted event.
fn emit_inference_complete(
  st: state.AgentState,
  model: String,
  _msg_count: Int,
  duration_ms: Int,
  response_id: option.Option(String),
  finish_reason: option.Option(String),
  input_tokens: option.Option(Int),
  output_tokens: option.Option(Int),
  message: Message,
  input_messages: List(Message),
) -> Nil {
  case get_dispatcher(st) {
    option.Some(disp) ->
      emit.to_dispatcher(
        disp,
        events.InferenceCompleted(
          message:,
          response_id:,
          response_model: option.Some(model),
          finish_reason:,
          input_tokens:,
          output_tokens:,
          duration_ms:,
          input_messages:,
        ),
      )
    option.None -> Nil
  }
}

/// Emit InferenceFailed event.
fn emit_inference_failed(
  st: state.AgentState,
  _model: String,
  _msg_count: Int,
  error_type: String,
  duration_ms: Int,
  input_messages: List(Message),
) -> Nil {
  case get_dispatcher(st) {
    option.Some(disp) -> {
      let error =
        case error_type {
          "ApiError" -> error.ApiError("")
          "RateLimited" -> error.RateLimited
          "Timeout" -> error.Timeout
          "InvalidResponse" -> error.InvalidResponse("")
          _ -> error.ApiError(error_type)
        }
      emit.to_dispatcher(
        disp,
        events.InferenceFailed(
          error:,
          duration_ms:,
          input_messages:,
        ),
      )
    }
    option.None -> Nil
  }
}

/// Emit ToolStarted event.
fn emit_tool_start(st: state.AgentState, call: ToolCall) -> Nil {
  case get_dispatcher(st) {
    option.Some(disp) -> emit.to_dispatcher(disp, events.ToolStarted(tool_call: call))
    option.None -> Nil
  }
}

/// Emit ToolExecuted event.
fn emit_tool_executed(
  st: state.AgentState,
  call: ToolCall,
  duration_ms: Int,
  result_str: String,
) -> Nil {
  case get_dispatcher(st) {
    option.Some(disp) ->
      emit.to_dispatcher(
        disp,
        events.ToolExecuted(
          tool_call: call,
          result: result_str,
          duration_ms:,
        ),
      )
    option.None -> Nil
  }
}

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
/// Emits `InferenceStarted` before the call and `InferenceCompleted` or
/// `InferenceFailed` after, with duration measurement.
pub fn step(st: state.AgentState) -> StepResult {
  let defs = state.tool_definitions(st)
  let msgs = state.messages_for_provider(st)
  let msg_count = list.length(msgs)
  let model = st.config.model

  emit_inference_start(st, model, msg_count)
  let start_time = events.system_time()

  let result = case st.config.provider(msgs, defs) {
    Ok(inference_result) -> {
      let msg = inference_result.message
      let meta = inference_result.metadata
      let updated = state.add_message(st, msg)
      let duration = events.system_time() - start_time
      emit_inference_complete(
        st,
        model,
        msg_count,
        duration,
        meta.response_id,
        meta.finish_reason,
        meta.input_tokens,
        meta.output_tokens,
        msg,
        msgs,
      )
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
      let duration = events.system_time() - start_time
      emit_inference_failed(
        st,
        model,
        msg_count,
        error_to_string(e),
        duration,
        msgs,
      )
      StepError(e)
    }
  }
  result
}

/// Execute tool calls against the registry and append results to history.
///
/// Emits `ToolStarted` and `ToolExecuted` for each tool call.
/// Errors are caught and turned into Tool messages — the LLM adapts.
pub fn execute_tools_and_advance(
  st: state.AgentState,
  calls: List(ToolCall),
) -> state.AgentState {
  let tool_messages =
    list.map(calls, fn(call) {
      emit_tool_start(st, call)
      let start_time = events.system_time()
      let result = execution.execute_tool(st.config.tools, call)
      let duration = events.system_time() - start_time
      let result_str = case result {
        Ok(json_result) -> json.to_string(json_result)
        Error(tool_err) -> "Tool error: " <> tool_err.message
      }
      emit_tool_executed(st, call, duration, result_str)
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
