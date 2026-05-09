//// Agent OTP actor — thin wrapper around the pure core.
////
//// Holds `AgentState` (config + history). History accumulates across
//// `run()` calls. Session lifecycle hooks fire on init and stop.
////
//// Logic lives in `pig/agent/core.gleam` and `pig/agent/parallel.gleam`.
//// This module is wiring only.

import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/string
import logging
import gleam/option
import gleam/otp/actor.{type StartError, Started}
import gleam/otp/supervision
import pig/agent/core
import pig/agent/parallel
import pig/agent/state
import pig/ai/error.{type AiError}
import pig/ai/message.{type Message, User}
import pig/hooks
import pig/obs/session

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
/// The actor holds `AgentState` — history accumulates across `run()` calls.
pub fn start(
  config: state.AgentConfig,
) -> Result(Subject(AgentMessage), StartError) {
  let initial_state = init_state(config)
  let builder =
    actor.new(initial_state)
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

/// Send a prompt to the agent and wait synchronously for a response.
///
/// Returns `Ok(result)` on success, `Error(Nil)` if the call times out
/// or the agent crashes. Unlike `run`, this never panics.
pub fn try_run(
  subject: Subject(AgentMessage),
  prompt: String,
  timeout: Int,
) -> Result(Result(Message, AiError), Nil) {
  try_call(subject, timeout, fn(reply_to) { Run(prompt, reply_to) })
}

@external(erlang, "pig_agent_try_call_ffi", "try_call")
fn try_call(
  subject: Subject(AgentMessage),
  timeout: Int,
  make_msg: fn(Subject(Result(Message, AiError))) -> AgentMessage,
) -> Result(Result(Message, AiError), Nil)

/// Send a stop message to the agent actor.
pub fn stop(subject: Subject(AgentMessage)) -> Nil {
  actor.send(subject, Stop)
}

/// Create a ChildSpecification for use with static_supervisor.
///
/// Starts a named actor so the Subject can be recovered after
/// supervisor start via `process.named_subject(name)`.
/// Returns `ChildSpecification(Nil)` — data is discarded per
/// static_supervisor convention.
pub fn supervised(
  config: state.AgentConfig,
  name: Name(AgentMessage),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let initial_state = init_state(config)
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

/// Internal: initialize agent state from config.
/// Fires session_start hooks if any are registered.
/// If session_path is set, replays history from JSONL.
fn init_state(config: state.AgentConfig) -> state.AgentState {
  let st = state.new(config)
  // Replay history from session file if path is set
  let st = case config.session_path {
    option.Some(path) -> {
      case session.replay(path) {
        Ok(replayed_messages) -> {
          let st_with_history =
            list.fold(replayed_messages, st, state.add_message)
          st_with_history
        }
        Error(e) -> {
          logging.log(
            logging.Warning,
            "Failed to replay session from "
              <> path
              <> ": "
              <> string.inspect(e),
          )
          st
        }
      }
    }
    option.None -> st
  }
  hooks.notify_session_start(
    config.hooks,
    hooks.SessionStartEvent(history: st.history),
  )
  st
}

/// Internal: message handler for the actor.
/// Holds AgentState — history accumulates across Run messages.
fn handle_message(
  st: state.AgentState,
  msg: AgentMessage,
) -> actor.Next(state.AgentState, AgentMessage) {
  case msg {
    Run(prompt, reply_to) -> {
      // Reset iterations for this run, add user message to accumulated history
      let st = state.AgentState(
        config: st.config,
        history: st.history,
        iterations: 0,
      )
      let st = state.add_message(st, User(prompt))
      let #(final_state, result) = do_run(st)
      process.send(reply_to, result)
      actor.continue(final_state)
    }
    Stop -> {
      // Fire session_shutdown hooks before stopping
      hooks.notify_session_shutdown(
        st.config.hooks,
        hooks.SessionShutdownEvent(
          history: st.history,
          iterations: st.iterations,
        ),
      )
      actor.stop()
    }
  }
}

/// Run the agent loop with parallel tool execution.
/// Returns the final state (with accumulated history) and the result.
fn do_run(st: state.AgentState) -> #(state.AgentState, Result(Message, AiError)) {
  case state.exceeded_max_iterations(st) {
    True -> #(st, Error(state.max_iterations_error(st)))
    False ->
      case core.step(st) {
        core.Complete(msg) -> {
          let final_st = state.add_message(st, msg)
          #(final_st, Ok(msg))
        }
        core.StepError(e) -> #(st, Error(e))
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
