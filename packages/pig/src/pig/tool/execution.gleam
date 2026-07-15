//// Tool execution compatibility API and batch validation.
////
//// `execute_tool` delegates to the canonical dispatch in `pig/tool`; batch
//// validation remains here because it is used by the agent runtime.

import gleam/dict
import gleam/json
import pig/tool.{type ToolCallBatchError, type ToolError, type ToolRegistry}
import pig_protocol/message.{type ToolCall}

/// Execute a tool call through canonical registry dispatch.
///
/// This compatibility API delegates to `tool.execute_tool`, which owns lookup,
/// argument decoding, context construction, and handler invocation.
pub fn execute_tool(
  registry: ToolRegistry,
  call: ToolCall,
) -> Result(json.Json, ToolError) {
  tool.execute_tool(registry, call)
}

/// Validate a batch before hooks, telemetry, or tool processes are started.
///
/// The first invalidity is selected left-to-right: an empty ID at its index,
/// or the second occurrence of a duplicated ID. Empty batches are valid.
pub fn validate_tool_calls(
  calls: List(ToolCall),
) -> Result(Nil, ToolCallBatchError) {
  validate_remaining(calls, dict.new(), 0)
}

fn validate_remaining(
  calls: List(ToolCall),
  seen: dict.Dict(String, Nil),
  index: Int,
) -> Result(Nil, ToolCallBatchError) {
  case calls {
    [] -> Ok(Nil)
    [call, ..] if call.id == "" -> Error(tool.EmptyToolCallId(index))
    [call, ..rest] -> {
      case dict.get(seen, call.id) {
        Ok(_) -> Error(tool.DuplicateToolCallId(call.id))
        Error(Nil) ->
          validate_remaining(rest, dict.insert(seen, call.id, Nil), index + 1)
      }
    }
  }
}
