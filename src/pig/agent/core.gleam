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
import pig/ai/error.{type AiError}
import pig/ai/message.{type Message, type ToolCall}
import pig/hooks
import pig/obs/dispatcher
import pig/obs/emit
import pig/obs/events
import pig/tool/execution

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
  provider_response_model: option.Option(String),
  finish_reason: option.Option(String),
  input_tokens: option.Option(Int),
  output_tokens: option.Option(Int),
  message: Message,
  input_messages: List(Message),
) -> Nil {
  // Prefer the model returned by the provider in the API response;
  // fall back to the config model when the provider doesn't supply one.
  let response_model = case provider_response_model {
    option.Some(_) as m -> m
    option.None -> option.Some(model)
  }
  case get_dispatcher(st) {
    option.Some(disp) ->
      emit.to_dispatcher(
        disp,
        events.InferenceCompleted(
          message:,
          response_id:,
          response_model:,
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
  error: AiError,
  duration_ms: Int,
  input_messages: List(Message),
) -> Nil {
  case get_dispatcher(st) {
    option.Some(disp) ->
      emit.to_dispatcher(
        disp,
        events.InferenceFailed(
          error:,
          duration_ms:,
          input_messages:,
        ),
      )
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

/// Emit ToolBlocked event.
fn emit_tool_blocked(
  st: state.AgentState,
  call: ToolCall,
  hook_name: String,
  reason: String,
) -> Nil {
  case get_dispatcher(st) {
    option.Some(disp) ->
      emit.to_dispatcher(
        disp,
        events.ToolBlocked(
          tool_call: call,
          hook_name:,
          reason:,
        ),
      )
    option.None -> Nil
  }
}

/// Emit HookActed event for each transformer name.
fn emit_hook_acted_list(
  st: state.AgentState,
  transformer_names: List(String),
  hook: events.HookPoint,
  description: String,
) -> Nil {
  case get_dispatcher(st) {
    option.Some(disp) ->
      list.each(transformer_names, fn(name) {
        emit.to_dispatcher(
          disp,
          events.HookActed(
            hook_name: name,
            hook_point: hook,
            action: events.HookActionDetail(
              action_type: "transform",
              description:,
            ),
          ),
        )
      })
    option.None -> Nil
  }
}

/// Helper to check if a result is an error.
fn result_is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
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
/// Applies before_inference hooks (decide_messages) to transform messages
/// before calling the provider.
///
/// Emits `InferenceStarted` before the call and `InferenceCompleted` or
/// `InferenceFailed` after, with duration measurement.
pub fn step(st: state.AgentState) -> StepResult {
  let defs = state.tool_definitions(st)
  let msgs = state.messages_for_provider(st)
  let model = st.config.model

  // Apply before_inference hooks to transform messages
  let before_event = hooks.BeforeInferenceEvent(model:, messages: msgs)
  let final_msgs = case hooks.decide_messages(st.config.hooks, before_event) {
    hooks.MessagesUnchanged(..) -> msgs
    hooks.MessagesReplaced(final_messages:, transformers:) -> {
      emit_hook_acted_list(
        st,
        transformers,
        events.BeforeInference,
        "Transformed messages before inference",
      )
      final_messages
    }
  }

  let msg_count = list.length(final_msgs)
  emit_inference_start(st, model, msg_count)
  let start_time = events.system_time()

  let result = case st.config.provider(final_msgs, defs) {
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
        meta.response_model,
        meta.finish_reason,
        meta.input_tokens,
        meta.output_tokens,
        msg,
        final_msgs,
      )
      // Fire after_inference hooks
      hooks.notify_after_inference(
        st.config.hooks,
        hooks.AfterInferenceEvent(model:, message: msg, duration_ms: duration),
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
        e,
        duration,
        final_msgs,
      )
      // Fire error hooks
      hooks.notify_error(
        st.config.hooks,
        hooks.ErrorEvent(model:, error: e),
      )
      StepError(e)
    }
  }
  result
}

/// Execute tool calls against the registry and append results to history.
///
/// For each tool call:
/// 1. Check hooks (decide_tool_call) — blocked tools get error Tool messages
/// 2. Execute allowed tools
/// 3. Apply result hooks (decide_tool_result) — transform results
///
/// Emits `ToolStarted`, `ToolExecuted`, `ToolBlocked`, `HookActed`.
/// Errors are caught and turned into Tool messages — the LLM adapts.
pub fn execute_tools_and_advance(
  st: state.AgentState,
  calls: List(ToolCall),
) -> state.AgentState {
  let tool_messages =
    list.map(calls, fn(call) {
      // Step 1: Check hooks for tool call decision
      let hook_event = hooks.ToolCallEvent(
        tool_name: call.name,
        tool_call_id: call.id,
        arguments_json: call.arguments_json,
      )
      case hooks.decide_tool_call(st.config.hooks, hook_event) {
        hooks.ToolAllowed -> {
          // Execute the tool normally
          emit_tool_start(st, call)
          let start_time = events.system_time()
          let result = execution.execute_tool(st.config.tools, call)
          let duration = events.system_time() - start_time
          let result_str = case result {
            Ok(json_result) -> json.to_string(json_result)
            Error(tool_err) -> "Tool error: " <> tool_err.message
          }
          emit_tool_executed(st, call, duration, result_str)

          // Step 3: Apply result hooks
          let raw_content = case result {
            Ok(json_result) -> json.to_string(json_result)
            Error(tool_err) -> "Tool error: " <> tool_err.message
          }
          let result_event = hooks.ToolResultEvent(
            tool_name: call.name,
            tool_call_id: call.id,
            result: raw_content,
            is_error: result_is_error(result),
            duration_ms: duration,
          )
          case hooks.decide_tool_result(st.config.hooks, result_event) {
            hooks.ResultUnchanged(..) ->
              message.Tool(
                tool_call_id: call.id,
                content: raw_content,
              )
            hooks.ResultTransformed(final_event:, transformers:) -> {
              emit_hook_acted_list(
                st,
                transformers,
                events.AfterToolCall,
                "Transformed result",
              )
              message.Tool(
                tool_call_id: call.id,
                content: final_event.result,
              )
            }
          }
        }
        hooks.ToolBlocked(hook_name:, reason:) -> {
          // Tool blocked by hook — emit observability and create error Tool message
          emit_tool_blocked(st, call, hook_name, reason)
          emit_hook_acted_list(
            st,
            [hook_name],
            events.BeforeToolCall,
            "Blocked tool: " <> reason,
          )
          let content =
            "Tool blocked by '" <> hook_name <> "': " <> reason
          message.Tool(tool_call_id: call.id, content:)
        }
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
    True -> {
      hooks.notify_error(
        st.config.hooks,
        hooks.ErrorEvent(model: st.config.model, error: state.max_iterations_error(st)),
      )
      Error(state.max_iterations_error(st))
    }
    False ->
      case step(st) {
        Complete(msg) -> {
          hooks.notify_complete(
            st.config.hooks,
            hooks.CompleteEvent(model: st.config.model, message: msg, total_iterations: st.iterations),
          )
          Ok(msg)
        }
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
