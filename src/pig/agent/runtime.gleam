//// Sans-IO runtime interpreter for the pig agent.
////
//// The runtime is an OTP actor that:
//// 1. Receives prompts (Run) or control messages (Stop)
//// 2. Calls `update.update(state, msg)` — pure state machine
//// 3. For each effect, applies hooks then executes
//// 4. Produces SessionEvent values and sends to dispatcher
//// 5. Feeds effect results back as new AgentMsg values
////
//// The core logic (update.gleam) is pure. This module is all IO.

import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor.{type StartError, Started}
import gleam/otp/supervision
import logging
import pig/agent/effect
import pig/agent/msg
import pig/agent/state
import pig/agent/step_result
import pig/agent/update
import pig/ai/error.{type AiError}
import pig/ai/message.{type Message, type ToolCall}
import pig/ai/provider
import pig/ai/tool_definition
import pig/hooks
import pig/obs/dispatcher
import pig/obs/emit
import pig/obs/events
import pig/tool
import pig/tool/execution

// ── Configuration ────────────────────────────────────────────────

/// Configuration for the runtime. Holds everything the runtime needs
/// that the pure core doesn't — provider function, tool registry,
/// hooks, dispatcher, and model name.
pub type RuntimeConfig {
  RuntimeConfig(
    provider: provider.Provider,
    tools: tool.ToolRegistry,
    hooks: List(hooks.Hooks),
    dispatcher: process.Subject(dispatcher.DispatcherMessage),
    model: String,
    max_iterations: Int,
  )
}

// ── Actor Messages ───────────────────────────────────────────────

/// Messages the runtime actor can receive.
pub type RuntimeMsg {
  /// Run a prompt and reply with the result.
  Run(prompt: String, reply_to: process.Subject(Result(Message, AiError)))
  /// Stop the actor.
  Stop
}

// ── Actor State ──────────────────────────────────────────────────

/// Internal state held by the runtime actor.
pub type RuntimeState {
  RuntimeState(agent_state: state.AgentState, config: RuntimeConfig)
}

// ── Start ────────────────────────────────────────────────────────

/// Start the runtime actor with the given configuration.
pub fn start(
  config: RuntimeConfig,
) -> Result(process.Subject(RuntimeMsg), StartError) {
  // Build initial AgentState from runtime config
  let agent_config =
    state.AgentConfig(
      provider: config.provider,
      tools: config.tools,
      system_prompt: option.None,
      max_iterations: config.max_iterations,
      model: config.model,
      agent_id: option.None,
      agent_name: option.None,
      agent_description: option.None,
      agent_version: option.None,
      provider_name: option.None,
      session_path: option.None,
    )
  let initial_state =
    RuntimeState(agent_state: state.new(agent_config), config:)
  start_with_state(config, initial_state)
}

/// Start the runtime actor with a pre-built state.
/// Used by `pig.gleam` when session replay needs to happen before start.
pub fn start_with_state(
  _config: RuntimeConfig,
  initial_state: RuntimeState,
) -> Result(process.Subject(RuntimeMsg), StartError) {
  let builder =
    actor.new(initial_state)
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Send a prompt to the runtime and wait for a response.
pub fn run(
  subject: process.Subject(RuntimeMsg),
  prompt: String,
  timeout: Int,
) -> Result(Message, AiError) {
  actor.call(subject, timeout, fn(reply_to) { Run(prompt, reply_to) })
}

/// Send a stop message to the runtime actor.
pub fn stop(subject: process.Subject(RuntimeMsg)) -> Nil {
  actor.send(subject, Stop)
}

/// Send a prompt to the runtime and wait for a response.
/// Returns `Error(Nil)` if the call times out or the runtime crashes.
pub fn try_run(
  subject: process.Subject(RuntimeMsg),
  prompt: String,
  timeout: Int,
) -> Result(Result(Message, AiError), Nil) {
  try_call(subject, timeout, fn(reply_to) { Run(prompt, reply_to) })
}

@external(erlang, "pig_agent_try_call_ffi", "try_call")
fn try_call(
  subject: process.Subject(RuntimeMsg),
  timeout: Int,
  make_msg: fn(process.Subject(Result(Message, AiError))) -> RuntimeMsg,
) -> Result(Result(Message, AiError), Nil)

/// Create a ChildSpecification for use with static_supervisor.
///
/// Starts a named actor so the Subject can be recovered after
/// supervisor start via `process.named_subject(name)`.
pub fn supervised(
  agent_config: state.AgentConfig,
  dispatcher_name: process.Name(dispatcher.DispatcherMessage),
  name: process.Name(RuntimeMsg),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let runtime_config =
      RuntimeConfig(
        provider: agent_config.provider,
        tools: agent_config.tools,
        hooks: [],
        dispatcher: process.named_subject(dispatcher_name),
        model: agent_config.model,
        max_iterations: agent_config.max_iterations,
      )
    let initial_state =
      RuntimeState(agent_state: state.new(agent_config), config: runtime_config)
    let builder =
      actor.new(initial_state)
      |> actor.on_message(handle_message)
      |> actor.named(name)
    case actor.start(builder) {
      Ok(started) -> Ok(Started(data: Nil, pid: started.pid))
      Error(e) -> Error(e)
    }
  })
}

// ── Message Handler ──────────────────────────────────────────────

fn handle_message(
  st: RuntimeState,
  m: RuntimeMsg,
) -> actor.Next(RuntimeState, RuntimeMsg) {
  case m {
    Run(prompt, reply_to) -> {
      // Reset iterations for this run, add user message
      let agent_st =
        state.AgentState(
          config: st.agent_state.config,
          history: st.agent_state.history,
          iterations: 0,
        )
      let result = execute_loop(st.config, agent_st, msg.UserPrompt(prompt))
      let #(final_state, outcome) = result
      process.send(reply_to, outcome)
      actor.continue(RuntimeState(agent_state: final_state, config: st.config))
    }
    Stop -> actor.stop()
  }
}

// ── The Loop ─────────────────────────────────────────────────────

/// Execute the sans-IO loop: call update, interpret effects, feed back.
/// Returns the final agent state and the result.
fn execute_loop(
  config: RuntimeConfig,
  agent_st: state.AgentState,
  initial_msg: msg.AgentMsg,
) -> #(state.AgentState, Result(Message, AiError)) {
  do_loop(config, agent_st, initial_msg)
}

fn do_loop(
  config: RuntimeConfig,
  agent_st: state.AgentState,
  m: msg.AgentMsg,
) -> #(state.AgentState, Result(Message, AiError)) {
  let result = update.update(agent_st, m)
  case result {
    step_result.Done(state: final_st, message: msg) -> #(final_st, Ok(msg))
    step_result.Failed(state: final_st, error: e) -> #(final_st, Error(e))
    step_result.Continue(state: new_st, effects: effs) -> {
      // Execute each effect and collect response messages
      let #(updated_st, response_msgs) =
        list.fold(effs, #(new_st, []), fn(acc, eff) {
          let #(st_acc, msgs_acc) = acc
          let #(new_st_acc, response_msg) = execute_effect(config, st_acc, eff)
          #(new_st_acc, list.append(msgs_acc, [response_msg]))
        })
      // Feed first response message back into the loop
      case response_msgs {
        [first_msg, ..] -> do_loop(config, updated_st, first_msg)
        [] ->
          // No effects returned responses (shouldn't happen)
          #(updated_st, Error(error.ApiError("no response from effects")))
      }
    }
  }
}

// ── Effect Execution ─────────────────────────────────────────────

/// Execute a single effect: apply hooks, execute, emit events.
fn execute_effect(
  config: RuntimeConfig,
  agent_st: state.AgentState,
  eff: effect.Effect(msg.AgentMsg),
) -> #(state.AgentState, msg.AgentMsg) {
  case eff {
    effect.CallProvider(messages:, tools:, on_response:) ->
      execute_call_provider(config, agent_st, messages, tools, on_response)
    effect.ExecuteTools(calls:, on_results:) ->
      execute_tools_effect(config, agent_st, calls, on_results)
  }
}

/// Execute CallProvider: apply before_inference hooks, call provider,
/// emit events, fire notification hooks.
fn execute_call_provider(
  config: RuntimeConfig,
  agent_st: state.AgentState,
  messages: List(Message),
  tools: List(tool_definition.ToolDefinition),
  on_response: fn(Result(provider.InferenceResult, AiError)) -> msg.AgentMsg,
) -> #(state.AgentState, msg.AgentMsg) {
  let disp = config.dispatcher
  let model = config.model

  // Apply before_inference hooks
  let before_event = hooks.BeforeInferenceEvent(model:, messages:)
  let final_msgs = case hooks.decide_messages(config.hooks, before_event) {
    hooks.MessagesUnchanged(..) -> messages
    hooks.MessagesReplaced(final_messages:, transformers:) -> {
      emit_hook_acted_list(
        disp,
        transformers,
        events.BeforeInference,
        "transform",
        "Transformed messages before inference",
      )
      final_messages
    }
  }

  let msg_count = list.length(final_msgs)
  emit.to_dispatcher(
    disp,
    events.InferenceStarted(model:, message_count: msg_count),
  )
  let start_time = events.system_time()

  let result = case config.provider(final_msgs, tools) {
    Ok(inference_result) -> {
      let msg = inference_result.message
      let meta = inference_result.metadata
      let duration = events.system_time() - start_time
      let response_model = case meta.response_model {
        option.Some(_) as m -> m
        option.None -> option.Some(model)
      }
      emit.to_dispatcher(
        disp,
        events.InferenceCompleted(
          message: msg,
          response_id: meta.response_id,
          response_model:,
          stop_reason: meta.stop_reason,
          input_tokens: meta.input_tokens,
          output_tokens: meta.output_tokens,
          duration_ms: duration,
          input_messages: agent_st.history,
        ),
      )
      // Fire after_inference hooks
      hooks.notify_after_inference(
        config.hooks,
        hooks.AfterInferenceEvent(model:, message: msg, duration_ms: duration),
      )
      Ok(inference_result)
    }
    Error(e) -> {
      let duration = events.system_time() - start_time
      emit.to_dispatcher(
        disp,
        events.InferenceFailed(
          error: e,
          duration_ms: duration,
          input_messages: agent_st.history,
        ),
      )
      // Fire error hooks
      hooks.notify_error(config.hooks, hooks.ErrorEvent(model:, error: e))
      Error(e)
    }
  }
  #(agent_st, on_response(result))
}

/// Execute ExecuteTools: apply tool call hooks, execute allowed tools
/// in parallel, apply result hooks, emit events.
fn execute_tools_effect(
  config: RuntimeConfig,
  agent_st: state.AgentState,
  calls: List(ToolCall),
  on_results: fn(List(#(ToolCall, Result(json.Json, tool.ToolError)))) ->
    msg.AgentMsg,
) -> #(state.AgentState, msg.AgentMsg) {
  let disp = config.dispatcher

  // Partition into blocked (handled inline) and allowed (spawned)
  let #(blocked, allowed) = partition_by_hook_decision(config.hooks, calls)

  // Emit ToolBlocked events
  list.each(blocked, fn(b) {
    emit.to_dispatcher(
      disp,
      events.ToolBlocked(
        tool_call: b.call,
        hook_name: b.hook_name,
        reason: b.reason,
      ),
    )
    emit.to_dispatcher(
      disp,
      events.HookActed(
        hook_name: b.hook_name,
        hook_point: events.BeforeToolCall,
        action: events.HookActionDetail(
          action_type: "block",
          description: "Blocked tool: " <> b.reason,
        ),
      ),
    )
  })

  // Spawn processes for allowed calls
  let results = spawn_and_collect(config, allowed)

  // Process results: emit events, apply hooks, build final results list
  // First pass: emit events and apply hooks for executed tools
  let _ =
    list.map(allowed, fn(call) {
      let assert Ok(#(result, duration)) = find_result(results, call.id)
      let raw_content = case result {
        Ok(json_result) -> json.to_string(json_result)
        Error(tool_err) -> "Tool error: " <> tool_err.message
      }
      // Apply result hooks
      let result_event =
        hooks.ToolResultEvent(
          tool_name: call.name,
          tool_call_id: call.id,
          result: raw_content,
          is_error: is_error(result),
          duration_ms: duration,
        )
      let final_content = case
        hooks.decide_tool_result(config.hooks, result_event)
      {
        hooks.ResultUnchanged(..) -> raw_content
        hooks.ResultTransformed(final_event:, transformers:) -> {
          emit_hook_acted_list(
            disp,
            transformers,
            events.AfterToolCall,
            "transform",
            "Transformed result",
          )
          final_event.result
        }
      }
      // Emit ToolExecuted
      emit.to_dispatcher(
        disp,
        events.ToolExecuted(
          tool_call: call,
          result: final_content,
          duration_ms: duration,
        ),
      )
    })

  // Build final results list in original call order
  let all_results =
    list.map(calls, fn(call) {
      case find_blocked(blocked, call.id) {
        Ok(b) -> #(
          call,
          Error(tool.ToolError(
            message: "Tool blocked by '" <> b.hook_name <> "': " <> b.reason,
          )),
        )
        Error(Nil) -> {
          let assert Ok(#(res, _dur)) = find_result(results, call.id)
          #(call, res)
        }
      }
    })

  #(agent_st, on_results(all_results))
}

// ── Parallel Tool Execution ──────────────────────────────────────

type BlockedTool {
  BlockedTool(call: ToolCall, hook_name: String, reason: String)
}

type ToolResult {
  ToolResult(
    call_id: String,
    result: Result(json.Json, tool.ToolError),
    duration_ms: Int,
  )
}

fn partition_by_hook_decision(
  hooks_list: List(hooks.Hooks),
  calls: List(ToolCall),
) -> #(List(BlockedTool), List(ToolCall)) {
  list.fold(calls, #([], []), fn(acc, call) {
    let #(blocked_acc, allowed_acc) = acc
    let hook_event =
      hooks.ToolCallEvent(
        tool_name: call.name,
        tool_call_id: call.id,
        arguments_json: call.arguments_json,
      )
    case hooks.decide_tool_call(hooks_list, hook_event) {
      hooks.ToolAllowed -> #(blocked_acc, list.append(allowed_acc, [call]))
      hooks.ToolBlocked(hook_name:, reason:) -> #(
        list.append(blocked_acc, [
          BlockedTool(call:, hook_name:, reason:),
        ]),
        allowed_acc,
      )
    }
  })
}

fn spawn_and_collect(
  config: RuntimeConfig,
  calls: List(ToolCall),
) -> List(ToolResult) {
  let disp = config.dispatcher
  let pairs =
    list.map(calls, fn(call) {
      let reply_subject = process.new_subject()
      let pid =
        process.spawn(fn() {
          emit.to_dispatcher(disp, events.ToolStarted(tool_call: call))
          let start_time = events.system_time()
          let result = execution.execute_tool(config.tools, call)
          let duration = events.system_time() - start_time
          process.send(reply_subject, ToolResult(call.id, result, duration))
        })
      #(pid, reply_subject, call.id)
    })
  let timeout_ms = 5000
  list.map(pairs, fn(pair) {
    let #(pid, subject, call_id) = pair
    case process.receive(subject, timeout_ms) {
      Ok(result) -> result
      Error(Nil) -> {
        process.kill(pid)
        logging.log(
          logging.Error,
          "Tool execution timed out after " <> int.to_string(timeout_ms) <> "ms",
        )
        ToolResult(
          call_id: call_id,
          result: Error(tool.ToolError(message: "Tool execution timed out")),
          duration_ms: timeout_ms,
        )
      }
    }
  })
}

fn find_blocked(
  blocked: List(BlockedTool),
  call_id: String,
) -> Result(BlockedTool, Nil) {
  list.find(blocked, fn(b) { b.call.id == call_id })
}

fn find_result(
  results: List(ToolResult),
  call_id: String,
) -> Result(#(Result(json.Json, tool.ToolError), Int), Nil) {
  case list.find(results, fn(r) { r.call_id == call_id }) {
    Ok(r) -> Ok(#(r.result, r.duration_ms))
    Error(Nil) -> Error(Nil)
  }
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

fn emit_hook_acted_list(
  disp: process.Subject(dispatcher.DispatcherMessage),
  transformer_names: List(String),
  hook: events.HookPoint,
  action_type: String,
  description: String,
) -> Nil {
  list.each(transformer_names, fn(name) {
    emit.to_dispatcher(
      disp,
      events.HookActed(
        hook_name: name,
        hook_point: hook,
        action: events.HookActionDetail(action_type:, description:),
      ),
    )
  })
}
