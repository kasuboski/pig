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
import gleam/result
import gleam/string
import logging
import pig/agent/effect
import pig/agent/msg
import pig/agent/state
import pig/agent/step_result
import pig/agent/update
import pig/hooks
import pig/obs/dispatcher
import pig/obs/emit
import pig/obs/events
import pig/provider.{type InferenceSettings}
import pig/run_error
import pig/session_store
import pig/tool
import pig/tool/execution
import pig_protocol/error.{type AiError}
import pig_protocol/message.{type Message, type ToolCall}
import pig_protocol/stop_reason
import pig_protocol/tool_definition

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
    inference_settings: InferenceSettings,
  )
}

// ── Actor Messages ───────────────────────────────────────────────

/// Messages the runtime actor can receive.
pub type RuntimeMsg {
  /// Run a prompt and reply with the result.
  Run(
    prompt: String,
    reply_to: process.Subject(Result(Message, run_error.RunError)),
  )
  /// Resume the agent loop from its current history.
  Continue(reply_to: process.Subject(Result(Message, run_error.RunError)))
  /// Replace the runtime's inference settings and reply synchronously.
  SetInferenceSettings(
    settings: InferenceSettings,
    reply_to: process.Subject(Result(Nil, run_error.RunError)),
  )
  /// Get the agent's current message history.
  GetHistory(reply_to: process.Subject(List(Message)))
  /// Stop the actor.
  Stop
}

// ── Actor State ──────────────────────────────────────────────────

/// The action to take only after a pending commit succeeds.
pub type PostCommitDisposition {
  ResumeFromHistory
  ReturnMessage(Message)
  ReturnAiError(AiError)
}

/// Durable session state held by the runtime.
pub type SessionState {
  /// No synchronous durable transcript is configured.
  SessionDisabled
  /// Commits are written to `store` against the current `head`.
  SessionReady(store: session_store.SessionStore, head: option.Option(String))
  /// A message commit failed ambiguously and must be retried unchanged.
  SessionPending(
    store: session_store.SessionStore,
    commit: session_store.SessionCommit,
    candidate: state.AgentState,
    disposition: PostCommitDisposition,
  )
  /// A settings commit failed ambiguously and must be retried unchanged.
  SessionSettingsPending(
    store: session_store.SessionStore,
    commit: session_store.SessionCommit,
    settings: InferenceSettings,
  )
}

/// Internal state held by the runtime actor.
pub type RuntimeState {
  RuntimeState(
    agent_state: state.AgentState,
    config: RuntimeConfig,
    session: SessionState,
    inference_settings: InferenceSettings,
  )
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
      inference_settings: config.inference_settings,
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
    runtime_state(
      agent_config,
      config,
      [],
      SessionDisabled,
      config.inference_settings,
    )
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
) -> Result(Message, run_error.RunError) {
  actor.call(subject, timeout, fn(reply_to) { Run(prompt, reply_to) })
}

/// Resume the agent loop from its current history.
///
/// Looks at the last message in history to determine the entry point:
/// - User/Tool message → call the provider
/// - Assistant with stop_reason=ToolUse → execute pending tool calls
/// - Assistant with stop_reason=Stop → return immediately
/// - Assistant with stop_reason=Length/Error → re-call provider
pub fn run_continue(
  subject: process.Subject(RuntimeMsg),
  timeout: Int,
) -> Result(Message, run_error.RunError) {
  actor.call(subject, timeout, fn(reply_to) { Continue(reply_to) })
}

/// Set inference settings and wait for the durable commit, when configured.
pub fn set_inference_settings(
  subject: process.Subject(RuntimeMsg),
  settings: InferenceSettings,
  timeout: Int,
) -> Result(Nil, run_error.RunError) {
  actor.call(subject, timeout, fn(reply_to) {
    SetInferenceSettings(settings:, reply_to:)
  })
}

/// Send a stop message to the runtime actor.
pub fn stop(subject: process.Subject(RuntimeMsg)) -> Nil {
  actor.send(subject, Stop)
}

/// Get the agent's current message history.
pub fn history(
  subject: process.Subject(RuntimeMsg),
  timeout: Int,
) -> List(Message) {
  actor.call(subject, timeout, fn(reply_to) { GetHistory(reply_to) })
}

/// Send a prompt to the runtime and wait for a response.
/// Returns `Error(Nil)` if the call times out or the runtime crashes.
pub fn try_run(
  subject: process.Subject(RuntimeMsg),
  prompt: String,
  timeout: Int,
) -> Result(Result(Message, run_error.RunError), Nil) {
  try_call(subject, timeout, fn(reply_to) { Run(prompt, reply_to) })
}

/// Resume the agent loop from its current history and wait for a response.
/// Returns `Error(Nil)` if the call times out or the runtime crashes.
pub fn try_run_continue(
  subject: process.Subject(RuntimeMsg),
  timeout: Int,
) -> Result(Result(Message, run_error.RunError), Nil) {
  try_call(subject, timeout, fn(reply_to) { Continue(reply_to) })
}

@external(erlang, "pig_agent_try_call_ffi", "try_call")
fn try_call(
  subject: process.Subject(RuntimeMsg),
  timeout: Int,
  make_msg: fn(process.Subject(Result(Message, run_error.RunError))) ->
    RuntimeMsg,
) -> Result(Result(Message, run_error.RunError), Nil)

/// Create a ChildSpecification for a named runtime actor.
///
/// `initial_history` becomes current before the actor starts, and `session`
/// carries the durable commit head associated with it. The Subject can be
/// recovered after supervisor start with `process.named_subject(name)`.
pub fn supervised(
  agent_config: state.AgentConfig,
  dispatcher_name: process.Name(dispatcher.DispatcherMessage),
  name: process.Name(RuntimeMsg),
  initial_history: List(Message),
  session: SessionState,
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    start_named_runtime(
      agent_config,
      dispatcher_name,
      name,
      initial_history,
      session,
      agent_config.inference_settings,
    )
  })
}

/// Create a durable ChildSpecification which reloads the session on every start.
///
/// A load failure during a later OTP restart is reported as actor initialisation
/// failure, allowing the supervisor to apply its usual restart policy.
pub fn supervised_with_session_store(
  agent_config: state.AgentConfig,
  dispatcher_name: process.Name(dispatcher.DispatcherMessage),
  name: process.Name(RuntimeMsg),
  store: session_store.SessionStore,
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let session_store.SessionStore(load:, ..) = store
    case load() {
      Ok(loaded) ->
        start_named_runtime(
          agent_config,
          dispatcher_name,
          name,
          state.strip_system_messages(loaded.messages),
          SessionReady(store:, head: loaded.head),
          case loaded.inference_settings {
            option.Some(settings) -> settings
            option.None -> agent_config.inference_settings
          },
        )
      Error(error) -> {
        logging.log(
          logging.Error,
          "Durable session reload failed: " <> string.inspect(error),
        )
        Error(actor.InitFailed(string.inspect(error)))
      }
    }
  })
}

fn start_named_runtime(
  agent_config: state.AgentConfig,
  dispatcher_name: process.Name(dispatcher.DispatcherMessage),
  name: process.Name(RuntimeMsg),
  initial_history: List(Message),
  session: SessionState,
  initial_settings: InferenceSettings,
) -> Result(actor.Started(Nil), StartError) {
  let runtime_config = supervised_runtime_config(agent_config, dispatcher_name)
  let initial_state =
    runtime_state(
      agent_config,
      runtime_config,
      initial_history,
      session,
      initial_settings,
    )
  let builder =
    actor.new(initial_state)
    |> actor.on_message(handle_message)
    |> actor.named(name)
  case actor.start(builder) {
    Ok(started) -> Ok(Started(data: Nil, pid: started.pid))
    Error(error) -> Error(error)
  }
}

fn supervised_runtime_config(
  agent_config: state.AgentConfig,
  dispatcher_name: process.Name(dispatcher.DispatcherMessage),
) -> RuntimeConfig {
  RuntimeConfig(
    provider: agent_config.provider,
    tools: agent_config.tools,
    hooks: [],
    dispatcher: process.named_subject(dispatcher_name),
    model: agent_config.model,
    max_iterations: agent_config.max_iterations,
    inference_settings: agent_config.inference_settings,
  )
}

fn runtime_state(
  agent_config: state.AgentConfig,
  config: RuntimeConfig,
  initial_history: List(Message),
  session: SessionState,
  initial_settings: InferenceSettings,
) -> RuntimeState {
  RuntimeState(
    agent_state: list.fold(
      initial_history,
      state.new(agent_config),
      state.add_message,
    ),
    config:,
    session:,
    inference_settings: initial_settings,
  )
}

// ── Message Handler ──────────────────────────────────────────────

fn handle_message(
  st: RuntimeState,
  m: RuntimeMsg,
) -> actor.Next(RuntimeState, RuntimeMsg) {
  case m {
    Run(prompt, reply_to) ->
      case st.session {
        SessionPending(..) | SessionSettingsPending(..) -> {
          process.send(
            reply_to,
            Error(run_error.Runtime(
              "cannot run a new prompt while a session commit is pending",
            )),
          )
          actor.continue(st)
        }
        _ -> {
          // Reset iterations for this run, add user message
          let agent_st =
            state.AgentState(
              config: st.agent_state.config,
              history: st.agent_state.history,
              iterations: 0,
            )
          let result =
            execute_loop(
              st.config,
              agent_st,
              st.session,
              st.inference_settings,
              msg.UserPrompt(prompt),
            )
          let #(final_state, final_session, outcome) = result
          process.send(reply_to, outcome)
          actor.continue(RuntimeState(
            agent_state: final_state,
            config: st.config,
            session: final_session,
            inference_settings: st.inference_settings,
          ))
        }
      }
    Continue(reply_to) -> {
      let #(final_state, final_session, outcome) = case st.session {
        SessionSettingsPending(..) -> #(
          st.agent_state,
          st.session,
          Error(run_error.Runtime(
            "cannot continue while inference settings commit is pending",
          )),
        )
        SessionPending(..) as pending ->
          retry_pending(
            st.config,
            st.agent_state,
            pending,
            st.inference_settings,
          )
        _ -> {
          let agent_st =
            state.AgentState(
              config: st.agent_state.config,
              history: st.agent_state.history,
              iterations: 0,
            )
          resume_from_history(
            st.config,
            agent_st,
            st.session,
            st.inference_settings,
          )
        }
      }
      process.send(reply_to, outcome)
      actor.continue(RuntimeState(
        agent_state: final_state,
        config: st.config,
        session: final_session,
        inference_settings: st.inference_settings,
      ))
    }
    SetInferenceSettings(settings, reply_to) -> {
      let #(next_session, outcome) = case st.session {
        SessionPending(..) -> #(
          st.session,
          Error(run_error.Runtime(
            "cannot change settings while a session commit is pending",
          )),
        )
        SessionSettingsPending(..) as pending ->
          retry_or_reject_settings(pending, settings)
        _ -> set_settings(st.session, settings)
      }
      process.send(reply_to, outcome)
      case outcome {
        Ok(Nil) -> {
          emit.to_dispatcher(
            st.config.dispatcher,
            events.InferenceSettingsChanged(settings:),
          )
          actor.continue(
            RuntimeState(
              ..st,
              session: next_session,
              inference_settings: settings,
            ),
          )
        }
        Error(_) -> actor.continue(RuntimeState(..st, session: next_session))
      }
    }
    GetHistory(reply_to) -> {
      process.send(reply_to, st.agent_state.history)
      actor.continue(st)
    }
    Stop -> actor.stop()
  }
}

fn set_settings(
  session: SessionState,
  settings: InferenceSettings,
) -> #(SessionState, Result(Nil, run_error.RunError)) {
  case session {
    SessionDisabled -> #(SessionDisabled, Ok(Nil))
    SessionReady(store:, head:) -> {
      let commit = session_store.new_settings_commit(head, settings)
      let session_store.SessionStore(commit: store_commit, ..) = store
      case store_commit(commit) {
        Error(error) ->
          settings_commit_error(store, head, commit, settings, error)
        Ok(committed) ->
          case committed.head == option.Some(commit.id) {
            True -> #(SessionReady(store:, head: committed.head), Ok(Nil))
            False -> #(
              SessionSettingsPending(store:, commit:, settings:),
              Error(
                run_error.Session(session_store.ParentConflict(
                  expected: option.Some(commit.id),
                  actual: committed.head,
                )),
              ),
            )
          }
      }
    }
    SessionPending(..) -> #(
      session,
      Error(run_error.Runtime(
        "cannot change settings while a session commit is pending",
      )),
    )
    SessionSettingsPending(..) -> #(
      session,
      Error(run_error.Runtime("inference settings commit is pending")),
    )
  }
}

fn retry_or_reject_settings(
  pending: SessionState,
  settings: InferenceSettings,
) -> #(SessionState, Result(Nil, run_error.RunError)) {
  let assert SessionSettingsPending(store:, commit:, settings: pending_settings) =
    pending
  case pending_settings == settings {
    False -> #(
      pending,
      Error(run_error.Runtime(
        "a different inference settings commit is pending",
      )),
    )
    True -> {
      let session_store.SessionStore(commit: store_commit, ..) = store
      case store_commit(commit) {
        Error(error) ->
          settings_commit_error(store, commit.parent, commit, settings, error)
        Ok(committed) ->
          case committed.head == option.Some(commit.id) {
            True -> #(SessionReady(store:, head: committed.head), Ok(Nil))
            False -> #(
              pending,
              Error(
                run_error.Session(session_store.ParentConflict(
                  expected: option.Some(commit.id),
                  actual: committed.head,
                )),
              ),
            )
          }
      }
    }
  }
}

fn settings_commit_error(
  store: session_store.SessionStore,
  head: option.Option(String),
  commit: session_store.SessionCommit,
  settings: InferenceSettings,
  error: session_store.SessionError,
) -> #(SessionState, Result(Nil, run_error.RunError)) {
  let next_session = case error {
    session_store.InvalidCommit(_) | session_store.Corrupt(_) ->
      SessionReady(store:, head:)
    session_store.Unavailable(_) | session_store.ParentConflict(..) ->
      SessionSettingsPending(store:, commit:, settings:)
  }
  #(next_session, Error(run_error.Session(error)))
}

// ── The Loop ─────────────────────────────────────────────────────

/// Execute the sans-IO loop: call update, interpret effects, feed back.
/// Returns the final agent state and the result.
fn execute_loop(
  config: RuntimeConfig,
  agent_st: state.AgentState,
  session: SessionState,
  settings: InferenceSettings,
  initial_msg: msg.AgentMsg,
) -> #(state.AgentState, SessionState, Result(Message, run_error.RunError)) {
  do_loop(config, agent_st, session, settings, initial_msg)
}

fn do_loop(
  config: RuntimeConfig,
  agent_st: state.AgentState,
  session: SessionState,
  settings: InferenceSettings,
  m: msg.AgentMsg,
) -> #(state.AgentState, SessionState, Result(Message, run_error.RunError)) {
  let transition = update.update(agent_st, m)
  case transition {
    step_result.Done(state: final_st, message: final_message) ->
      commit_or_pending(
        config,
        session,
        agent_st,
        final_st,
        settings,
        ReturnMessage(final_message),
      )

    step_result.Failed(state: final_st, error: inference_error) ->
      commit_or_pending(
        config,
        session,
        agent_st,
        final_st,
        settings,
        ReturnAiError(inference_error),
      )

    step_result.Continue(state: new_st, effects: effs) ->
      case commit_transition(session, agent_st, new_st, ResumeFromHistory) {
        Error(#(pending, session_error)) -> #(
          agent_st,
          pending,
          Error(run_error.Session(session_error)),
        )
        Ok(next_session) ->
          execute_effects(config, new_st, next_session, settings, effs)
      }
  }
}

fn commit_or_pending(
  config: RuntimeConfig,
  session: SessionState,
  previous: state.AgentState,
  candidate: state.AgentState,
  settings: InferenceSettings,
  disposition: PostCommitDisposition,
) -> #(state.AgentState, SessionState, Result(Message, run_error.RunError)) {
  case commit_transition(session, previous, candidate, disposition) {
    Ok(next_session) ->
      complete_disposition(
        config,
        candidate,
        next_session,
        settings,
        disposition,
      )
    Error(#(pending, session_error)) -> #(
      previous,
      pending,
      Error(run_error.Session(session_error)),
    )
  }
}

fn commit_transition(
  session: SessionState,
  previous: state.AgentState,
  candidate: state.AgentState,
  disposition: PostCommitDisposition,
) -> Result(SessionState, #(SessionState, session_store.SessionError)) {
  let delta = list.drop(candidate.history, list.length(previous.history))
  case session, delta {
    SessionPending(..), _ | SessionSettingsPending(..), _ ->
      panic as "cannot commit while a session commit is pending"
    _, [] -> Ok(session)
    SessionDisabled, _ -> Ok(session)
    SessionReady(store:, head:), messages ->
      commit_messages(store, head, messages, candidate, disposition)
  }
}

fn commit_messages(
  store: session_store.SessionStore,
  head: option.Option(String),
  messages: List(Message),
  candidate: state.AgentState,
  disposition: PostCommitDisposition,
) -> Result(SessionState, #(SessionState, session_store.SessionError)) {
  let session_store.SessionStore(commit: store_commit, ..) = store
  let commit = session_store.new_commit(head, messages)
  case store_commit(commit) {
    Ok(committed) ->
      accept_committed_session(store, commit, candidate, disposition, committed)
    Error(session_error) ->
      Error(#(
        SessionPending(store:, commit:, candidate:, disposition:),
        session_error,
      ))
  }
}

fn accept_committed_session(
  store: session_store.SessionStore,
  commit: session_store.SessionCommit,
  candidate: state.AgentState,
  disposition: PostCommitDisposition,
  committed: session_store.Session,
) -> Result(SessionState, #(SessionState, session_store.SessionError)) {
  case committed.head == option.Some(commit.id) {
    True -> Ok(SessionReady(store:, head: committed.head))
    False ->
      Error(#(
        SessionPending(store:, commit:, candidate:, disposition:),
        session_store.ParentConflict(
          expected: option.Some(commit.id),
          actual: committed.head,
        ),
      ))
  }
}

fn retry_pending(
  config: RuntimeConfig,
  current: state.AgentState,
  pending: SessionState,
  settings: InferenceSettings,
) -> #(state.AgentState, SessionState, Result(Message, run_error.RunError)) {
  let assert SessionPending(store:, commit:, candidate:, disposition:) = pending
  let session_store.SessionStore(commit: store_commit, ..) = store
  case store_commit(commit) {
    Error(session_error) -> #(
      current,
      SessionPending(store:, commit:, candidate:, disposition:),
      Error(run_error.Session(session_error)),
    )
    Ok(committed) ->
      case
        accept_committed_session(
          store,
          commit,
          candidate,
          disposition,
          committed,
        )
      {
        Ok(ready) ->
          complete_disposition(config, candidate, ready, settings, disposition)
        Error(#(still_pending, session_error)) -> #(
          current,
          still_pending,
          Error(run_error.Session(session_error)),
        )
      }
  }
}

fn complete_disposition(
  config: RuntimeConfig,
  candidate: state.AgentState,
  session: SessionState,
  settings: InferenceSettings,
  disposition: PostCommitDisposition,
) -> #(state.AgentState, SessionState, Result(Message, run_error.RunError)) {
  case disposition {
    ReturnMessage(message) -> #(candidate, session, Ok(message))
    ReturnAiError(error) -> #(
      candidate,
      session,
      Error(run_error.Inference(error)),
    )
    ResumeFromHistory ->
      resume_from_history(config, candidate, session, settings)
  }
}

fn execute_effects(
  config: RuntimeConfig,
  agent_st: state.AgentState,
  session: SessionState,
  settings: InferenceSettings,
  effs: List(effect.Effect(msg.AgentMsg)),
) -> #(state.AgentState, SessionState, Result(Message, run_error.RunError)) {
  // Effects begin only after the complete transition delta is durable.
  let #(updated_st, response_msgs) =
    list.fold(effs, #(agent_st, []), fn(acc, eff) {
      let #(st_acc, msgs_acc) = acc
      let #(new_st_acc, response_msg) =
        execute_effect(config, st_acc, settings, eff)
      #(new_st_acc, list.append(msgs_acc, [response_msg]))
    })
  case response_msgs {
    [first_msg, ..] -> do_loop(config, updated_st, session, settings, first_msg)
    [] -> #(
      updated_st,
      session,
      Error(run_error.Runtime("no response from effects")),
    )
  }
}

/// Resume the agent loop from its current history.
///
/// Determines the entry point by inspecting the last message in history.
/// This enables the durability pattern: an external system checkpoints
/// messages, and on retry, rebuilds history from those checkpoints.
fn resume_from_history(
  config: RuntimeConfig,
  st: state.AgentState,
  session: SessionState,
  settings: InferenceSettings,
) -> #(state.AgentState, SessionState, Result(Message, run_error.RunError)) {
  case list.last(st.history) {
    // No history — nothing to continue
    Error(_) -> #(
      st,
      session,
      Error(run_error.Runtime("no history to continue")),
    )

    Ok(last_msg) -> {
      case last_msg {
        // Assistant message — decide based on stop_reason and tool_calls
        message.Assistant(
          content: _,
          tool_calls: tool_calls,
          thinking: _,
          stop_reason: sr,
        ) ->
          resume_from_assistant(config, st, session, settings, tool_calls, sr)

        // User or Tool message — call provider (through hooks pipeline)
        message.User(_) | message.Tool(_, _) -> {
          let #(st_after, provider_msg) =
            execute_call_provider(
              config,
              st,
              state.messages_for_provider(st),
              state.tool_definitions(st),
              settings,
              fn(r) {
                msg.ProviderResponded(result.map(r, fn(ir) { ir.message }))
              },
            )
          do_loop(config, st_after, session, settings, provider_msg)
        }

        // System message at end of history — shouldn't happen
        message.System(_) -> #(
          st,
          session,
          Error(run_error.Runtime("unexpected system message at end of history")),
        )
      }
    }
  }
}

/// Decide how to resume based on the last assistant message's stop_reason
/// and tool_calls.
fn resume_from_assistant(
  config: RuntimeConfig,
  st: state.AgentState,
  session: SessionState,
  settings: InferenceSettings,
  tool_calls: List(message.ToolCall),
  sr: option.Option(stop_reason.StopReason),
) -> #(state.AgentState, SessionState, Result(Message, run_error.RunError)) {
  case sr {
    // Tool calls pending — execute them, then continue loop
    option.Some(stop_reason.ToolUse) -> {
      let #(_new_st, agent_msg) =
        execute_tools_effect(config, st, settings, tool_calls, fn(results) {
          msg.ToolResults(results)
        })
      do_loop(config, st, session, settings, agent_msg)
    }

    // Done — completed on a previous attempt
    option.Some(stop_reason.Stop) -> {
      let assert Ok(msg) = list.last(st.history)
      #(st, session, Ok(msg))
    }

    // Hit token limit or error — re-call provider (through hooks pipeline)
    option.Some(stop_reason.Length)
    | option.Some(stop_reason.Error)
    | option.Some(stop_reason.Unknown(_)) -> {
      let #(st_after, provider_msg) =
        execute_call_provider(
          config,
          st,
          state.messages_for_provider(st),
          state.tool_definitions(st),
          settings,
          fn(r) { msg.ProviderResponded(result.map(r, fn(ir) { ir.message })) },
        )
      do_loop(config, st_after, session, settings, provider_msg)
    }

    // No stop_reason (legacy messages) — decide by tool_calls presence
    option.None ->
      case tool_calls {
        [] -> {
          // No tool calls, no stop_reason — treat as done
          let assert Ok(msg) = list.last(st.history)
          #(st, session, Ok(msg))
        }
        calls -> {
          // Has tool calls but no stop_reason — execute them
          let #(_new_st, agent_msg) =
            execute_tools_effect(config, st, settings, calls, fn(results) {
              msg.ToolResults(results)
            })
          do_loop(config, st, session, settings, agent_msg)
        }
      }
  }
}

// ── Effect Execution ─────────────────────────────────────────────

/// Execute a single effect: apply hooks, execute, emit events.
fn execute_effect(
  config: RuntimeConfig,
  agent_st: state.AgentState,
  settings: InferenceSettings,
  eff: effect.Effect(msg.AgentMsg),
) -> #(state.AgentState, msg.AgentMsg) {
  case eff {
    effect.CallProvider(messages:, tools:, on_response:) ->
      execute_call_provider(
        config,
        agent_st,
        messages,
        tools,
        settings,
        on_response,
      )
    effect.ExecuteTools(calls:, on_results:) ->
      execute_tools_effect(config, agent_st, settings, calls, on_results)
  }
}

/// Execute CallProvider: apply before_inference hooks, call provider,
/// emit events, fire notification hooks.
fn execute_call_provider(
  config: RuntimeConfig,
  agent_st: state.AgentState,
  messages: List(Message),
  tools: List(tool_definition.ToolDefinition),
  settings: InferenceSettings,
  on_response: fn(Result(provider.InferenceResult, AiError)) -> msg.AgentMsg,
) -> #(state.AgentState, msg.AgentMsg) {
  let disp = config.dispatcher
  let model = config.model

  // Apply before_inference hooks
  let before_event = hooks.BeforeInferenceEvent(model:, messages:, settings:)
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
    events.InferenceStarted(model:, message_count: msg_count, settings:),
  )
  let start_time = events.system_time()

  let request =
    provider.InferenceRequest(messages: final_msgs, tools:, settings:)
  let result = case config.provider(request) {
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
          settings:,
        ),
      )
      // Fire after_inference hooks
      hooks.notify_after_inference(
        config.hooks,
        hooks.AfterInferenceEvent(
          model:,
          message: msg,
          duration_ms: duration,
          settings:,
        ),
      )
      Ok(inference_result)
    }
    Error(e) -> {
      let duration = events.system_time() - start_time
      emit.to_dispatcher(
        disp,
        events.InferenceFailed(
          model:,
          error: e,
          duration_ms: duration,
          input_messages: agent_st.history,
          settings:,
        ),
      )
      // Fire error hooks
      hooks.notify_error(
        config.hooks,
        hooks.ErrorEvent(model:, error: e, settings:),
      )
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
  _settings: InferenceSettings,
  calls: List(ToolCall),
  on_results: fn(List(#(ToolCall, Result(json.Json, tool.ToolError)))) ->
    msg.AgentMsg,
) -> #(state.AgentState, msg.AgentMsg) {
  // Reject the whole batch before hooks, telemetry, or processes can observe it.
  case execution.validate_tool_calls(calls) {
    Error(batch_error) -> {
      let rejected =
        list.map(calls, fn(call) {
          #(call, Error(tool.InvalidToolCallBatch(batch_error)))
        })
      #(agent_st, on_results(rejected))
    }
    Ok(Nil) -> execute_valid_tools_effect(config, agent_st, calls, on_results)
  }
}

fn execute_valid_tools_effect(
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
        Error(tool_err) -> "Tool error: " <> tool.error_message(tool_err)
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
