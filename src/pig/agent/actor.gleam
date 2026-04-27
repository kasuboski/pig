//// Agent OTP actor — thin wrapper around the pure core.
////
//// Holds `AgentConfig` (immutable). Each `Run` creates fresh `AgentState`,
//// runs to completion, and returns the result. No state bleeds between runs.
////
//// Logic lives in `pig/agent/core.gleam` and `pig/agent/parallel.gleam`.
//// This module is wiring only.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor.{type StartError}
import pig/agent/core
import pig/agent/parallel
import pig/agent/state
import pig/ai/error.{type AiError}
import pig/ai/message.{type Message, User}

/// Messages the agent actor can receive.
pub type AgentMessage {
  /// Run a prompt and reply with the result.
  Run(prompt: String, reply_to: Subject(Result(Message, AiError)))
  /// Stop the actor.
  Stop
}

/// Start an agent actor with the given configuration.
///
/// Returns a `Subject(AgentMessage)` for sending messages to the actor.
pub fn start(
  config: state.AgentConfig,
) -> Result(Subject(AgentMessage), StartError) {
  let builder =
    actor.new(config)
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Send a prompt to the agent and wait synchronously for a response.
///
/// Panics if the actor doesn't respond within `timeout` milliseconds.
pub fn run(
  subject: Subject(AgentMessage),
  prompt: String,
  timeout: Int,
) -> Result(Message, AiError) {
  actor.call(subject, timeout, fn(reply_to) { Run(prompt, reply_to) })
}

/// Send a stop message to the agent actor.
pub fn stop(subject: Subject(AgentMessage)) -> Nil {
  actor.send(subject, Stop)
}

/// Internal: message handler for the actor.
fn handle_message(
  config: state.AgentConfig,
  msg: AgentMessage,
) -> actor.Next(state.AgentConfig, AgentMessage) {
  case msg {
    Run(prompt, reply_to) -> {
      let st =
        state.new(config)
        |> state.add_message(User(prompt))
      let result = do_run(st)
      process.send(reply_to, result)
      actor.continue(config)
    }
    Stop -> actor.stop()
  }
}

/// Run the agent loop with parallel tool execution.
/// Reimplements core.run_to_completion but uses parallel tool execution
/// instead of sequential.
fn do_run(st: state.AgentState) -> Result(Message, AiError) {
  case state.exceeded_max_iterations(st) {
    True -> Error(state.max_iterations_error(st))
    False ->
      case core.step(st) {
        core.Complete(msg) -> Ok(msg)
        core.StepError(e) -> Error(e)
        core.NeedsToolExecution(calls, updated_state) -> {
          let advanced =
            updated_state
            |> state.increment_iterations()
            |> parallel.execute_tools_and_advance(calls)
          do_run(advanced)
        }
      }
  }
}
