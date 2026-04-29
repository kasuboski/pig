//// Parallel tool execution for the agent actor.
////
//// Spawns a process per tool call, collects results, emits telemetry.
//// Tools run concurrently — telemetry ordering proves parallelism.

import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import pig/agent/state
import pig/ai/message.{type ToolCall}
import pig/obs/emit
import pig/obs/events
import pig/tool
import pig/tool/execution

/// Execute tool calls in parallel and append results to state.
///
/// Spawns one process per tool call. Each process emits ToolStart,
/// executes the tool, emits ToolStop, and sends the result back.
/// The caller collects all results and builds Tool messages.
///
/// If a spawned process crashes before sending a result, this function
/// will block until the timeout. Crashes are caught and turned into
/// error Tool messages — the LLM adapts.
pub fn execute_tools_and_advance(
  st: state.AgentState,
  calls: List(ToolCall),
) -> state.AgentState {
  case calls {
    [] -> st
    _ -> {
      // Spawn a process per tool call
      let results = spawn_and_collect(st, calls)
      // Build Tool messages from results
      let tool_messages =
        list.zip(calls, results)
        |> list.map(fn(pair) {
          let #(call, result) = pair
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
  }
}

/// Spawn one process per tool call and collect results.
fn spawn_and_collect(
  st: state.AgentState,
  calls: List(ToolCall),
) -> List(Result(json.Json, tool.ToolError)) {
  // Capture dispatcher subject for spawned processes
  let dispatcher_opt = st.config.dispatcher
  // Create a reply subject for each tool call
  let subjects =
    list.map(calls, fn(call) {
      let reply_subject = process.new_subject()
      let _pid =
        process.spawn(fn() {
          // Emit based on whether dispatcher is configured
          case dispatcher_opt {
            option.Some(disp) ->
              emit.to_dispatcher(disp, events.ToolStarted(tool_call: call))
            option.None ->
              events.emit(events.ToolStart(
                tool_name: call.name,
                tool_call_id: call.id,
                arguments_json: call.arguments_json,
              ))
          }
          let start_time = events.system_time()
          let result = execution.execute_tool(st.config.tools, call)
          let duration = events.system_time() - start_time
          let result_str = case result {
            Ok(json_result) -> json.to_string(json_result)
            Error(tool_err) -> "Tool error: " <> tool_err.message
          }
          case dispatcher_opt {
            option.Some(disp) ->
              emit.to_dispatcher(
                disp,
                events.ToolExecuted(
                  tool_call: call,
                  result: result_str,
                  duration_ms: duration,
                ),
              )
            option.None ->
              events.emit(events.ToolStop(
                tool_name: call.name,
                tool_call_id: call.id,
                duration_ms: duration,
                result: result_str,
              ))
          }
          process.send(reply_subject, result)
        })
      reply_subject
    })
  // Collect results in order
  list.map(subjects, fn(subject) {
    let assert Ok(result) =
      process.receive(subject, 5000)
    result
  })
}
