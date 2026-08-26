//// Tool batch reduction and hook partitioning for the runtime.

import gleam/json
import gleam/list
import pig/agent/tool_worker
import pig/hooks
import pig/tool
import pig_protocol/message.{type ToolCall}

@internal
pub type ActiveTool {
  ActiveTool(call: ToolCall, worker: tool_worker.Worker, started_at: Int)
}

@internal
pub type ToolOutcome {
  ToolOutcome(
    call: ToolCall,
    result: Result(json.Json, tool.ToolError),
    duration_ms: Int,
  )
}

@internal
pub type ToolBatch {
  ToolBatch(
    round: Int,
    calls: List(ToolCall),
    active: List(ActiveTool),
    outcomes: List(ToolOutcome),
  )
}

@internal
pub type BlockedTool {
  BlockedTool(call: ToolCall, hook_name: String, reason: String)
}

@internal
pub type Completion {
  Ignored
  Finished(outcomes: List(ToolOutcome))
  Waiting(batch: ToolBatch)
}

@internal
pub fn finish(
  batch: ToolBatch,
  call: ToolCall,
  result: Result(json.Json, tool.ToolError),
  duration_ms: Int,
) -> Completion {
  case list.find(batch.active, fn(item) { item.call == call }) {
    Error(Nil) -> Ignored
    Ok(_) -> {
      let remaining = list.filter(batch.active, fn(item) { item.call != call })
      let outcomes = [
        ToolOutcome(call:, result:, duration_ms:),
        ..batch.outcomes
      ]
      case remaining {
        [] -> Finished(outcomes)
        _ -> Waiting(ToolBatch(..batch, active: remaining, outcomes:))
      }
    }
  }
}

@internal
pub fn ordered_results(
  calls: List(ToolCall),
  outcomes: List(ToolOutcome),
) -> List(#(ToolCall, Result(json.Json, tool.ToolError))) {
  list.map(calls, fn(call) {
    let assert Ok(outcome) = list.find(outcomes, fn(item) { item.call == call })
    #(call, outcome.result)
  })
}

@internal
pub fn partition_by_hook_decision(
  hooks_list: List(hooks.Hooks),
  calls: List(ToolCall),
) -> #(List(BlockedTool), List(ToolCall)) {
  list.fold(calls, #([], []), fn(acc, call) {
    let #(blocked, allowed) = acc
    let event =
      hooks.ToolCallEvent(
        tool_name: call.name,
        tool_call_id: call.id,
        arguments_json: call.arguments_json,
      )
    case hooks.decide_tool_call(hooks_list, event) {
      hooks.ToolAllowed -> #(blocked, list.append(allowed, [call]))
      hooks.ToolBlocked(hook_name:, reason:) -> #(
        list.append(blocked, [BlockedTool(call:, hook_name:, reason:)]),
        allowed,
      )
    }
  })
}

@internal
pub fn result_content(result: Result(json.Json, tool.ToolError)) -> String {
  case result {
    Ok(value) -> json.to_string(value)
    Error(error) -> "Tool error: " <> tool.error_message(error)
  }
}

@internal
pub fn is_error(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> False
    Error(_) -> True
  }
}
