//// Parallel tool execution for the agent actor.
////
//// Spawns a process per tool call, collects results, emits telemetry.
//// Tools run concurrently — telemetry ordering proves parallelism.

import gleam/dict
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import pig/agent/state
import pig/ai/message.{type ToolCall}
import pig/hooks
import pig/obs/dispatcher
import pig/obs/emit
import pig/obs/events
import pig/tool
import pig/tool/execution

/// Execute tool calls in parallel and append results to state.
///
/// For each tool call:
/// 1. Check hooks (decide_tool_call) — blocked tools get error Tool messages
/// 2. Spawn a process for each allowed tool call
/// 3. Apply result hooks (decide_tool_result) — transform results
///
/// Blocked tools do NOT spawn processes — they get error Tool messages inline.
/// Spawns one process per allowed tool call. Each process emits ToolStarted,
/// executes the tool, emits ToolExecuted, and sends the result back.
pub fn execute_tools_and_advance(
  st: state.AgentState,
  calls: List(ToolCall),
) -> state.AgentState {
  case calls {
    [] -> st
    _ -> {
      // Partition into blocked (handled inline) and allowed (spawned)
      let #(blocked_msgs, allowed_calls) =
        partition_by_hook_decision(st.config.hooks, calls)

      // Emit ToolBlocked events for blocked calls
      let disp = get_dispatcher(st)
      list.each(blocked_msgs, fn(blocked) {
        case disp {
          option.Some(d) -> {
            emit.to_dispatcher(
              d,
              events.ToolBlocked(
                tool_call: blocked.call,
                hook_name: blocked.hook_name,
                reason: blocked.reason,
              ),
            )
            emit.to_dispatcher(
              d,
              events.HookActed(
                hook_name: blocked.hook_name,
                hook_point: events.BeforeToolCall,
                action: events.HookActionDetail(
                  action_type: "block",
                  description: "Blocked tool: " <> blocked.reason,
                ),
              ),
            )
          }
          option.None -> Nil
        }
      })

      // Spawn processes for allowed calls (returns results with durations)
      let results = spawn_and_collect(st, allowed_calls)

      // Build lookup maps for blocked and executed messages keyed by call.id
      let blocked_map =
        list.fold(blocked_msgs, dict.new(), fn(m, b) {
          dict.insert(m, b.call.id, b)
        })

      let executed_map =
        list.fold(list.zip(allowed_calls, results), dict.new(), fn(m, pair) {
          let #(call, result_and_dur) = pair
          let #(result, duration) = result_and_dur
          let raw_content = case result {
            Ok(json_result) -> json.to_string(json_result)
            Error(tool_err) -> "Tool error: " <> tool_err.message
          }
          // Apply result hooks with real duration
          let result_event = hooks.ToolResultEvent(
            tool_name: call.name,
            tool_call_id: call.id,
            result: raw_content,
            is_error: is_error(result),
            duration_ms: duration,
          )
          let final_content = case hooks.decide_tool_result(
            st.config.hooks,
            result_event,
          ) {
            hooks.ResultUnchanged(..) -> raw_content
            hooks.ResultTransformed(final_event:, transformers:) -> {
              emit_hook_acted_list(
                st,
                transformers,
                events.AfterToolCall,
                "transform",
                "Transformed result",
              )
              final_event.result
            }
          }
          // Emit ToolExecuted with post-hook content and real duration
          let disp = get_dispatcher(st)
          case disp {
            option.Some(d) ->
              emit.to_dispatcher(
                d,
                events.ToolExecuted(
                  tool_call: call,
                  result: final_content,
                  duration_ms: duration,
                ),
              )
            option.None -> Nil
          }
          dict.insert(m, call.id, final_content)
        })

      // Reconstruct messages in original call order
      let all_messages =
        list.map(calls, fn(call) {
          case dict.get(blocked_map, call.id) {
            Ok(b) -> {
              let content =
                "Tool blocked by '" <> b.hook_name <> "': " <> b.reason
              message.Tool(tool_call_id: call.id, content:)
            }
            Error(_) -> {
              let assert Ok(content) = dict.get(executed_map, call.id)
              message.Tool(tool_call_id: call.id, content:)
            }
          }
        })

      list.fold(all_messages, st, state.add_message)
    }
  }
}

type BlockedTool {
  BlockedTool(call: ToolCall, hook_name: String, reason: String)
}

/// Partition tool calls by hook decision.
/// Returns #(blocked, allowed).
fn partition_by_hook_decision(
  hooks_list: List(hooks.Hooks),
  calls: List(ToolCall),
) -> #(List(BlockedTool), List(ToolCall)) {
  let #(blocked, allowed) =
    list.fold(calls, #([], []), fn(acc, call) {
      let #(blocked_acc, allowed_acc) = acc
      let hook_event = hooks.ToolCallEvent(
        tool_name: call.name,
        tool_call_id: call.id,
        arguments_json: call.arguments_json,
      )
      case hooks.decide_tool_call(hooks_list, hook_event) {
        hooks.ToolAllowed ->
          #(blocked_acc, list.append(allowed_acc, [call]))
        hooks.ToolBlocked(hook_name:, reason:) ->
          #(
            list.append(blocked_acc, [
              BlockedTool(call:, hook_name:, reason:),
            ]),
            allowed_acc,
          )
      }
    })
  #(blocked, allowed)
}

fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}

/// Emit HookActed event for each transformer name.
fn emit_hook_acted_list(
  st: state.AgentState,
  transformer_names: List(String),
  hook: events.HookPoint,
  action_type: String,
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
              action_type:,
              description:,
            ),
          ),
        )
      })
    option.None -> Nil
  }
}

/// Spawn one process per tool call and collect results with durations.
/// ToolStarted is emitted in the spawned process; ToolExecuted is emitted
/// by the caller after hooks have been applied.
fn spawn_and_collect(
  st: state.AgentState,
  calls: List(ToolCall),
) -> List(#(Result(json.Json, tool.ToolError), Int)) {
  // Capture dispatcher subject for spawned processes
  let disp = get_dispatcher(st)
  // Create a reply subject for each tool call
  let subjects =
    list.map(calls, fn(call) {
      let reply_subject = process.new_subject()
      let _pid =
        process.spawn(fn() {
          case disp {
            option.Some(d) ->
              emit.to_dispatcher(d, events.ToolStarted(tool_call: call))
            option.None -> Nil
          }
          let start_time = events.system_time()
          let result = execution.execute_tool(st.config.tools, call)
          let duration = events.system_time() - start_time
          process.send(reply_subject, #(result, duration))
        })
      reply_subject
    })
  // Collect results in order
  list.map(subjects, fn(subject) {
    let assert Ok(pair) =
      process.receive(subject, 5000)
    pair
  })
}

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
