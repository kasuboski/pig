//// Pure recovery decisions for resuming a durable agent run.

import gleam/erlang/process
import gleam/list
import gleam/option
import pig/agent/durable_session
import pig/agent/state
import pig/hooks
import pig/provider
import pig/run as agent_run
import pig/run_error
import pig_protocol/message.{type Message, type ToolCall}
import pig_protocol/stop_reason

@internal
pub type RecoveryAction {
  Resume
  StartInference
  StartTools(calls: List(ToolCall))
  Complete(message: Message)
  Fail(error: run_error.RunError)
}

@internal
pub type Terminal {
  Completed(provider.InferenceResult)
  TermFailed(run_error.RunError)
  TermCancelled(run_error.CancelReason)
}

@internal
pub fn from_history(agent_state: state.AgentState) -> RecoveryAction {
  case list.last(agent_state.history) {
    Error(_) -> Fail(run_error.Runtime("no history to continue"))
    Ok(last_message) -> from_last_message(last_message)
  }
}

@internal
pub fn from_disposition(
  disposition: durable_session.PostCommitDisposition,
) -> RecoveryAction {
  case disposition {
    durable_session.ResumeFromHistory -> Resume
    durable_session.ReturnMessage(message) -> Complete(message)
    durable_session.ReturnAiError(error) -> Fail(run_error.Inference(error))
  }
}

@internal
pub fn completion_result(
  last_inference: option.Option(provider.InferenceResult),
  message: Message,
) -> provider.InferenceResult {
  case last_inference {
    option.Some(result) if result.message == message -> result
    _ -> provider.from_message(message)
  }
}

@internal
pub fn notify_terminal(
  terminal: Terminal,
  hooks_list: List(hooks.Hooks),
  model: String,
  total_iterations: Int,
  sink: process.Subject(agent_run.RunEvent),
) -> Nil {
  case terminal {
    Completed(result) -> {
      hooks.notify_complete(
        hooks_list,
        hooks.CompleteEvent(model:, message: result.message, total_iterations:),
      )
      process.send(sink, agent_run.Completed(result:))
    }
    TermFailed(error) -> process.send(sink, agent_run.Failed(error))
    TermCancelled(reason) -> process.send(sink, agent_run.Cancelled(reason:))
  }
}

fn from_last_message(last_message: Message) -> RecoveryAction {
  case last_message {
    message.Assistant(tool_calls:, stop_reason:, ..) ->
      from_assistant(last_message, tool_calls, stop_reason)
    message.User(_) | message.Tool(_, _) -> StartInference
    message.System(_) ->
      Fail(run_error.Runtime("unexpected system message at end of history"))
  }
}

fn from_assistant(
  assistant: Message,
  tool_calls: List(ToolCall),
  reason: option.Option(stop_reason.StopReason),
) -> RecoveryAction {
  case reason {
    option.Some(stop_reason.ToolUse) -> StartTools(tool_calls)
    option.Some(stop_reason.Stop) -> Complete(assistant)
    option.Some(stop_reason.Length)
    | option.Some(stop_reason.Error)
    | option.Some(stop_reason.Unknown(_)) -> StartInference
    option.None ->
      case tool_calls {
        [] -> Complete(assistant)
        _ -> StartTools(tool_calls)
      }
  }
}
