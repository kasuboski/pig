//// Message-driven runtime interpreter for the pure pig agent core.
////
//// The runtime owns one run lifecycle at a time. Provider coordination and
//// tool execution live in cancellable workers, so the actor remains available
//// for cancellation, history, and settings messages while effects are active.

import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleam/otp/actor.{type StartError, Started}
import gleam/otp/supervision
import gleam/string
import logging
import pig/agent/client_watcher
import pig/agent/durable_session
import pig/agent/effect
import pig/agent/inference_worker
import pig/agent/msg
import pig/agent/run_recovery
import pig/agent/state
import pig/agent/step_result
import pig/agent/tool_batch
import pig/agent/tool_worker
import pig/agent/update
import pig/hooks
import pig/obs/dispatcher
import pig/obs/emit
import pig/obs/events
import pig/provider.{type InferenceSettings}
import pig/run as agent_run
import pig/run_error
import pig/session_store
import pig/tool
import pig/tool/execution
import pig_protocol/error.{type AiError}
import pig_protocol/message.{type Message, type ToolCall}
import pig_protocol/tool_definition

/// Configuration owned by one runtime actor.
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

/// Messages accepted by the runtime actor.
pub type RuntimeMsg {
  StartPrompt(
    prompt: String,
    sink: process.Subject(agent_run.RunEvent),
    terminal: process.Subject(agent_run.RunEvent),
    owner: option.Option(process.Pid),
    reply_to: process.Subject(Result(agent_run.Run, run_error.RunStartError)),
  )
  StartContinue(
    sink: process.Subject(agent_run.RunEvent),
    terminal: process.Subject(agent_run.RunEvent),
    owner: option.Option(process.Pid),
    reply_to: process.Subject(Result(agent_run.Run, run_error.RunStartError)),
  )
  CancelRun(run_id: String, reason: run_error.CancelReason)
  WatchClient(run_id: String, owner: process.Pid)
  InferenceWorkerEvent(
    run_id: String,
    round: Int,
    event: provider.InferenceEvent,
  )
  ToolWorkerFinished(
    run_id: String,
    round: Int,
    call: ToolCall,
    result: Result(json.Json, tool.ToolError),
    duration_ms: Int,
  )
  SetInferenceSettings(
    settings: InferenceSettings,
    reply_to: process.Subject(Result(Nil, run_error.RunError)),
  )
  GetHistory(reply_to: process.Subject(List(Message)))
  Stop(reply_to: process.Subject(Nil))
}

/// Action retained with an ambiguous durable commit.
pub type PostCommitDisposition =
  durable_session.PostCommitDisposition

/// Durable session state held by the runtime.
pub type SessionState {
  SessionDisabled
  SessionReady(store: session_store.SessionStore, head: option.Option(String))
  SessionPending(
    store: session_store.SessionStore,
    commit: session_store.SessionCommit,
    candidate: state.AgentState,
    disposition: PostCommitDisposition,
  )
  SessionSettingsPending(
    store: session_store.SessionStore,
    settings: InferenceSettings,
    mode: SettingsPendingMode,
  )
}

/// Recovery mode for a durable settings transition.
pub type SettingsPendingMode =
  durable_session.SettingsPendingMode

type Activity {
  Idle
  Running(ActiveRun)
}

type ActiveRun {
  ActiveRun(
    id: String,
    sink: process.Subject(agent_run.RunEvent),
    run: agent_run.Run,
    round: Int,
    phase: RunPhase,
    watcher: option.Option(client_watcher.Watch),
    last_inference: option.Option(provider.InferenceResult),
  )
}

type RunPhase {
  Preparing
  AwaitingInference(InferenceOperation)
  AwaitingTools(tool_batch.ToolBatch)
}

type InferenceOperation {
  InferenceOperation(
    round: Int,
    worker: inference_worker.Worker,
    started_at: Int,
    input_messages: List(Message),
    settings: InferenceSettings,
  )
}

/// Internal state held by the runtime actor.
pub opaque type RuntimeState {
  RuntimeState(
    agent_state: state.AgentState,
    config: RuntimeConfig,
    session: durable_session.SessionState,
    inference_settings: InferenceSettings,
    activity: Activity,
    mailbox: option.Option(process.Subject(RuntimeMsg)),
  )
}

/// Construct runtime state around a pre-built pure agent state.
pub fn initial_state(
  agent_state: state.AgentState,
  config: RuntimeConfig,
  session: SessionState,
  inference_settings: InferenceSettings,
) -> RuntimeState {
  RuntimeState(
    agent_state:,
    config:,
    session: to_durable_session(session),
    inference_settings:,
    activity: Idle,
    mailbox: option.None,
  )
}

/// Start a runtime from low-level configuration.
pub fn start(
  config: RuntimeConfig,
) -> Result(process.Subject(RuntimeMsg), StartError) {
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
  start_with_state(
    config,
    initial_state(
      state.new(agent_config),
      config,
      SessionDisabled,
      config.inference_settings,
    ),
  )
}

/// Start a runtime with replayed history and durable session state.
pub fn start_with_state(
  _config: RuntimeConfig,
  initial: RuntimeState,
) -> Result(process.Subject(RuntimeMsg), StartError) {
  let builder =
    actor.new_with_initialiser(1000, fn(subject) {
      initial
      |> attach_mailbox(subject)
      |> actor.initialised
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(error) -> Error(error)
  }
}

/// Start a run and infer the watched client from the caller-owned sink.
pub fn stream(
  subject: process.Subject(RuntimeMsg),
  prompt: String,
  sink: process.Subject(agent_run.RunEvent),
) -> Result(agent_run.Run, run_error.RunStartError) {
  let terminal = process.new_subject()
  start_prompt(subject, prompt, sink, terminal, sink_owner(sink))
}

/// Start a run with an explicit process to watch for client disconnection.
pub fn stream_owned(
  subject: process.Subject(RuntimeMsg),
  prompt: String,
  sink: process.Subject(agent_run.RunEvent),
  owner: process.Pid,
) -> Result(agent_run.Run, run_error.RunStartError) {
  let terminal = process.new_subject()
  start_prompt(subject, prompt, sink, terminal, option.Some(owner))
}

/// Continue history and infer the watched client from the caller-owned sink.
pub fn stream_continue(
  subject: process.Subject(RuntimeMsg),
  sink: process.Subject(agent_run.RunEvent),
) -> Result(agent_run.Run, run_error.RunStartError) {
  let terminal = process.new_subject()
  start_continuation(subject, sink, terminal, sink_owner(sink))
}

/// Continue history with an explicit process to watch for disconnection.
pub fn stream_continue_owned(
  subject: process.Subject(RuntimeMsg),
  sink: process.Subject(agent_run.RunEvent),
  owner: process.Pid,
) -> Result(agent_run.Run, run_error.RunStartError) {
  let terminal = process.new_subject()
  start_continuation(subject, sink, terminal, option.Some(owner))
}

fn start_prompt(
  subject: process.Subject(RuntimeMsg),
  prompt: String,
  sink: process.Subject(agent_run.RunEvent),
  terminal: process.Subject(agent_run.RunEvent),
  owner: option.Option(process.Pid),
) -> Result(agent_run.Run, run_error.RunStartError) {
  case process.subject_owner(subject) {
    Error(Nil) -> Error(run_error.RuntimeStartUnavailable)
    Ok(runtime_pid) -> {
      let reply_to = process.new_subject()
      let monitor = process.monitor(runtime_pid)
      process.send(
        subject,
        StartPrompt(prompt:, sink:, terminal:, owner:, reply_to:),
      )
      await_start_reply(reply_to, monitor)
    }
  }
}

fn start_continuation(
  subject: process.Subject(RuntimeMsg),
  sink: process.Subject(agent_run.RunEvent),
  terminal: process.Subject(agent_run.RunEvent),
  owner: option.Option(process.Pid),
) -> Result(agent_run.Run, run_error.RunStartError) {
  case process.subject_owner(subject) {
    Error(Nil) -> Error(run_error.RuntimeStartUnavailable)
    Ok(runtime_pid) -> {
      let reply_to = process.new_subject()
      let monitor = process.monitor(runtime_pid)
      process.send(subject, StartContinue(sink:, terminal:, owner:, reply_to:))
      await_start_reply(reply_to, monitor)
    }
  }
}

type StartWaitMessage {
  StartReply(Result(agent_run.Run, run_error.RunStartError))
  RuntimeDown
}

fn await_start_reply(
  reply_to: process.Subject(Result(agent_run.Run, run_error.RunStartError)),
  runtime_monitor: process.Monitor,
) -> Result(agent_run.Run, run_error.RunStartError) {
  let selector =
    process.new_selector()
    |> process.select_map(reply_to, StartReply)
    |> process.select_specific_monitor(runtime_monitor, fn(_) { RuntimeDown })
  case process.selector_receive_forever(selector) {
    StartReply(result) -> {
      process.demonitor_process(runtime_monitor)
      result
    }
    RuntimeDown ->
      case process.receive(reply_to, 0) {
        Ok(result) -> result
        Error(Nil) -> Error(run_error.RuntimeStartUnavailable)
      }
  }
}

fn sink_owner(
  sink: process.Subject(agent_run.RunEvent),
) -> option.Option(process.Pid) {
  case process.subject_owner(sink) {
    Ok(owner) -> option.Some(owner)
    Error(Nil) -> option.None
  }
}

/// Collect a run stream into the final message. The timeout actively cancels.
pub fn collect(
  run: agent_run.Run,
  sink: process.Subject(agent_run.RunEvent),
  timeout_ms: Int,
) -> Result(Message, run_error.RunError) {
  agent_run.collect(run, sink, timeout_ms, agent_run.runtime_owner(run))
}

/// Collect a prompt run using the caller's timeout.
pub fn run(
  subject: process.Subject(RuntimeMsg),
  prompt: String,
  timeout: Int,
) -> Result(Message, run_error.RunError) {
  let sink = process.new_subject()
  case stream(subject, prompt, sink) {
    Ok(run) -> collect(run, sink, timeout)
    Error(error) -> Error(start_error_to_run_error(error))
  }
}

/// Collect a continuation using the caller's timeout.
pub fn run_continue(
  subject: process.Subject(RuntimeMsg),
  timeout: Int,
) -> Result(Message, run_error.RunError) {
  let sink = process.new_subject()
  case stream_continue(subject, sink) {
    Ok(run) -> collect(run, sink, timeout)
    Error(error) -> Error(start_error_to_run_error(error))
  }
}

/// Transitional non-panicking collector. Deadline remains the outer error.
pub fn try_run(
  subject: process.Subject(RuntimeMsg),
  prompt: String,
  timeout: Int,
) -> Result(Result(Message, run_error.RunError), Nil) {
  case run(subject, prompt, timeout) {
    Error(run_error.Cancelled(run_error.DeadlineExceeded)) -> Error(Nil)
    Error(run_error.RuntimeUnavailable) -> Error(Nil)
    outcome -> Ok(outcome)
  }
}

/// Transitional non-panicking continuation collector.
pub fn try_run_continue(
  subject: process.Subject(RuntimeMsg),
  timeout: Int,
) -> Result(Result(Message, run_error.RunError), Nil) {
  case run_continue(subject, timeout) {
    Error(run_error.Cancelled(run_error.DeadlineExceeded)) -> Error(Nil)
    Error(run_error.RuntimeUnavailable) -> Error(Nil)
    outcome -> Ok(outcome)
  }
}

fn start_error_to_run_error(
  error: run_error.RunStartError,
) -> run_error.RunError {
  case error {
    run_error.Busy -> run_error.Runtime("agent is busy")
    run_error.Rejected(error) -> error
    run_error.RuntimeStartUnavailable -> run_error.RuntimeUnavailable
  }
}

/// Set inference settings and wait for a durable commit when configured.
pub fn set_inference_settings(
  subject: process.Subject(RuntimeMsg),
  settings: InferenceSettings,
  timeout: Int,
) -> Result(Nil, run_error.RunError) {
  actor.call(subject, timeout, fn(reply_to) {
    SetInferenceSettings(settings:, reply_to:)
  })
}

/// Get committed conversation history.
pub fn history(
  subject: process.Subject(RuntimeMsg),
  timeout: Int,
) -> List(Message) {
  actor.call(subject, timeout, fn(reply_to) { GetHistory(reply_to) })
}

/// Stop the actor after cancelling any active work with `AgentStopped`.
pub fn stop(subject: process.Subject(RuntimeMsg)) -> Nil {
  case process.subject_owner(subject) {
    Error(Nil) -> Nil
    Ok(_) -> {
      let reply_to = process.new_subject()
      process.send(subject, Stop(reply_to:))
      let _ = process.receive(reply_to, 5000)
      Nil
    }
  }
}

/// Create a child specification for a named runtime actor.
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

/// Create a durable child specification which reloads on every restart.
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
  let config = supervised_runtime_config(agent_config, dispatcher_name)
  let initial =
    initial_state(
      list.fold(initial_history, state.new(agent_config), state.add_message),
      config,
      session,
      initial_settings,
    )
  let builder =
    actor.new_with_initialiser(1000, fn(subject) {
      initial
      |> attach_mailbox(subject)
      |> actor.initialised
      |> actor.returning(Nil)
      |> Ok
    })
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

fn attach_mailbox(
  runtime_state: RuntimeState,
  mailbox: process.Subject(RuntimeMsg),
) -> RuntimeState {
  RuntimeState(..runtime_state, mailbox: option.Some(mailbox))
}

fn runtime_mailbox(runtime_state: RuntimeState) -> process.Subject(RuntimeMsg) {
  let assert option.Some(mailbox) = runtime_state.mailbox
  mailbox
}

fn handle_message(
  runtime_state: RuntimeState,
  message: RuntimeMsg,
) -> actor.Next(RuntimeState, RuntimeMsg) {
  case message {
    StartPrompt(prompt, sink, terminal, owner, reply_to) ->
      actor.continue(handle_start_prompt(
        runtime_state,
        prompt,
        sink,
        terminal,
        owner,
        reply_to,
      ))
    StartContinue(sink, terminal, owner, reply_to) ->
      actor.continue(handle_start_continue(
        runtime_state,
        sink,
        terminal,
        owner,
        reply_to,
      ))
    CancelRun(run_id, reason) ->
      actor.continue(cancel_matching_run(runtime_state, run_id, reason))
    WatchClient(run_id, owner) ->
      actor.continue(replace_client_watch(runtime_state, run_id, owner))
    InferenceWorkerEvent(run_id, round, event) ->
      actor.continue(handle_inference_event(runtime_state, run_id, round, event))
    ToolWorkerFinished(run_id, round, call, result, duration_ms) ->
      actor.continue(handle_tool_finished(
        runtime_state,
        run_id,
        round,
        call,
        result,
        duration_ms,
      ))
    SetInferenceSettings(settings, reply_to) -> {
      let #(next_state, outcome) = set_runtime_settings(runtime_state, settings)
      process.send(reply_to, outcome)
      case outcome {
        Ok(Nil) -> {
          emit.to_dispatcher(
            runtime_state.config.dispatcher,
            events.InferenceSettingsChanged(settings:),
          )
          actor.continue(
            RuntimeState(..next_state, inference_settings: settings),
          )
        }
        Error(_) -> actor.continue(next_state)
      }
    }
    GetHistory(reply_to) -> {
      process.send(reply_to, runtime_state.agent_state.history)
      actor.continue(runtime_state)
    }
    Stop(reply_to) -> {
      let _ = cancel_current_run(runtime_state, run_error.AgentStopped)
      process.send(reply_to, Nil)
      actor.stop()
    }
  }
}

fn handle_start_prompt(
  runtime_state: RuntimeState,
  prompt: String,
  sink: process.Subject(agent_run.RunEvent),
  terminal: process.Subject(agent_run.RunEvent),
  owner: option.Option(process.Pid),
  reply_to: process.Subject(Result(agent_run.Run, run_error.RunStartError)),
) -> RuntimeState {
  case runtime_state.activity {
    Running(_) -> {
      process.send(reply_to, Error(run_error.Busy))
      runtime_state
    }
    Idle ->
      case runtime_state.session {
        durable_session.SessionPending(..)
        | durable_session.SessionSettingsPending(..) -> {
          process.send(
            reply_to,
            Error(
              run_error.Rejected(run_error.Runtime(
                "cannot run a new prompt while a session commit is pending",
              )),
            ),
          )
          runtime_state
        }
        _ -> {
          let accepted =
            accept_run(runtime_state, sink, terminal, owner, reply_to)
          let reset = state.AgentState(..accepted.agent_state, iterations: 0)
          advance(
            RuntimeState(..accepted, agent_state: reset),
            msg.UserPrompt(prompt),
          )
        }
      }
  }
}

fn handle_start_continue(
  runtime_state: RuntimeState,
  sink: process.Subject(agent_run.RunEvent),
  terminal: process.Subject(agent_run.RunEvent),
  owner: option.Option(process.Pid),
  reply_to: process.Subject(Result(agent_run.Run, run_error.RunStartError)),
) -> RuntimeState {
  case runtime_state.activity {
    Running(_) -> {
      process.send(reply_to, Error(run_error.Busy))
      runtime_state
    }
    Idle -> handle_idle_continue(runtime_state, sink, terminal, owner, reply_to)
  }
}

fn handle_idle_continue(
  runtime_state: RuntimeState,
  sink: process.Subject(agent_run.RunEvent),
  terminal: process.Subject(agent_run.RunEvent),
  owner: option.Option(process.Pid),
  reply_to: process.Subject(Result(agent_run.Run, run_error.RunStartError)),
) -> RuntimeState {
  case runtime_state.session {
    durable_session.SessionSettingsPending(..) ->
      reject_settings_continue(runtime_state, reply_to)
    durable_session.SessionPending(..) as pending ->
      continue_pending_session(
        runtime_state,
        sink,
        terminal,
        owner,
        reply_to,
        pending,
      )
    _ -> continue_from_history(runtime_state, sink, terminal, owner, reply_to)
  }
}

fn reject_settings_continue(
  runtime_state: RuntimeState,
  reply_to: process.Subject(Result(agent_run.Run, run_error.RunStartError)),
) -> RuntimeState {
  process.send(
    reply_to,
    Error(
      run_error.Rejected(run_error.Runtime(
        "cannot continue while inference settings commit is pending",
      )),
    ),
  )
  runtime_state
}

fn continue_pending_session(
  runtime_state: RuntimeState,
  sink: process.Subject(agent_run.RunEvent),
  terminal: process.Subject(agent_run.RunEvent),
  owner: option.Option(process.Pid),
  reply_to: process.Subject(Result(agent_run.Run, run_error.RunStartError)),
  pending: durable_session.SessionState,
) -> RuntimeState {
  let accepted = accept_run(runtime_state, sink, terminal, owner, reply_to)
  case retry_pending_commit(pending) {
    Error(#(still_pending, error)) ->
      fail_run(
        RuntimeState(..accepted, session: still_pending),
        run_error.Session(error),
      )
    Ok(#(candidate, ready, disposition)) -> {
      let recovered =
        RuntimeState(..accepted, agent_state: candidate, session: ready)
      resume_disposition(recovered, disposition)
    }
  }
}

fn continue_from_history(
  runtime_state: RuntimeState,
  sink: process.Subject(agent_run.RunEvent),
  terminal: process.Subject(agent_run.RunEvent),
  owner: option.Option(process.Pid),
  reply_to: process.Subject(Result(agent_run.Run, run_error.RunStartError)),
) -> RuntimeState {
  let accepted = accept_run(runtime_state, sink, terminal, owner, reply_to)
  let reset = state.AgentState(..accepted.agent_state, iterations: 0)
  resume_from_history(RuntimeState(..accepted, agent_state: reset))
}

fn accept_run(
  runtime_state: RuntimeState,
  sink: process.Subject(agent_run.RunEvent),
  terminal: process.Subject(agent_run.RunEvent),
  owner: option.Option(process.Pid),
  reply_to: process.Subject(Result(agent_run.Run, run_error.RunStartError)),
) -> RuntimeState {
  let run_id = agent_run.fresh_id()
  let mailbox = runtime_mailbox(runtime_state)
  let handle =
    agent_run.new(
      run_id,
      process.self(),
      terminal,
      fn(reason) { process.send(mailbox, CancelRun(run_id, reason)) },
      fn(client) { process.send(mailbox, WatchClient(run_id, client)) },
    )
  let watcher =
    option.map(owner, fn(client) {
      client_watcher.start(client, fn() {
        process.send(mailbox, CancelRun(run_id, run_error.ClientDisconnected))
      })
    })
  let active =
    ActiveRun(
      id: run_id,
      sink:,
      run: handle,
      round: 0,
      phase: Preparing,
      watcher:,
      last_inference: option.None,
    )
  process.send(sink, agent_run.RunStarted)
  process.send(reply_to, Ok(handle))
  RuntimeState(..runtime_state, activity: Running(active))
}

fn replace_client_watch(
  runtime_state: RuntimeState,
  run_id: String,
  owner: process.Pid,
) -> RuntimeState {
  case runtime_state.activity {
    Running(active) if active.id == run_id -> {
      client_watcher.stop_option(active.watcher)
      let mailbox = runtime_mailbox(runtime_state)
      let watcher =
        client_watcher.start(owner, fn() {
          process.send(mailbox, CancelRun(run_id, run_error.ClientDisconnected))
        })
      RuntimeState(
        ..runtime_state,
        activity: Running(ActiveRun(..active, watcher: option.Some(watcher))),
      )
    }
    _ -> runtime_state
  }
}

fn advance(runtime_state: RuntimeState, message: msg.AgentMsg) -> RuntimeState {
  let transition = update.update(runtime_state.agent_state, message)
  case transition {
    step_result.Continue(state: candidate, effect:) ->
      case
        commit_transition(
          runtime_state.session,
          runtime_state.agent_state,
          candidate,
          durable_session.ResumeFromHistory,
        )
      {
        Ok(next_session) ->
          start_effect(
            RuntimeState(
              ..runtime_state,
              agent_state: candidate,
              session: next_session,
            ),
            effect,
          )
        Error(#(pending, error)) ->
          fail_run(
            RuntimeState(..runtime_state, session: pending),
            run_error.Session(error),
          )
      }
    step_result.Done(state: candidate, message: final_message) ->
      case
        commit_transition(
          runtime_state.session,
          runtime_state.agent_state,
          candidate,
          durable_session.ReturnMessage(final_message),
        )
      {
        Ok(next_session) ->
          complete_run(
            RuntimeState(
              ..runtime_state,
              agent_state: candidate,
              session: next_session,
            ),
            final_message,
          )
        Error(#(pending, error)) ->
          fail_run(
            RuntimeState(..runtime_state, session: pending),
            run_error.Session(error),
          )
      }
    step_result.Failed(state: candidate, error:) ->
      case
        commit_transition(
          runtime_state.session,
          runtime_state.agent_state,
          candidate,
          durable_session.ReturnAiError(error),
        )
      {
        Ok(next_session) ->
          fail_run(
            RuntimeState(
              ..runtime_state,
              agent_state: candidate,
              session: next_session,
            ),
            run_error.Inference(error),
          )
        Error(#(pending, session_error)) ->
          fail_run(
            RuntimeState(..runtime_state, session: pending),
            run_error.Session(session_error),
          )
      }
  }
}

fn start_effect(
  runtime_state: RuntimeState,
  requested_effect: effect.Effect,
) -> RuntimeState {
  case requested_effect {
    effect.CallProvider(messages:, tools:) ->
      start_inference(runtime_state, messages, tools)
    effect.ExecuteTools(calls:) -> start_tools(runtime_state, calls)
  }
}

fn start_inference(
  runtime_state: RuntimeState,
  messages: List(Message),
  tools: List(tool_definition.ToolDefinition),
) -> RuntimeState {
  let assert Running(active) = runtime_state.activity
  let settings = runtime_state.inference_settings
  let before_event =
    hooks.BeforeInferenceEvent(
      model: runtime_state.config.model,
      messages:,
      settings:,
    )
  let final_messages = case
    hooks.decide_messages(runtime_state.config.hooks, before_event)
  {
    hooks.MessagesUnchanged(..) -> messages
    hooks.MessagesReplaced(final_messages:, transformers:) -> {
      emit_hook_acted_list(
        runtime_state.config.dispatcher,
        transformers,
        events.BeforeInference,
        "transform",
        "Transformed messages before inference",
      )
      final_messages
    }
  }
  let round = active.round + 1
  let request =
    provider.InferenceRequest(messages: final_messages, tools:, settings:)
  emit.to_dispatcher(
    runtime_state.config.dispatcher,
    events.InferenceStarted(
      model: runtime_state.config.model,
      message_count: list.length(final_messages),
      settings:,
    ),
  )
  process.send(active.sink, agent_run.InferenceStarted(round:))
  let mailbox = runtime_mailbox(runtime_state)
  let run_id = active.id
  let worker =
    inference_worker.start(runtime_state.config.provider, request, fn(event) {
      process.send(mailbox, InferenceWorkerEvent(run_id, round, event))
    })
  let operation =
    InferenceOperation(
      round:,
      worker:,
      started_at: events.system_time(),
      input_messages: final_messages,
      settings:,
    )
  RuntimeState(
    ..runtime_state,
    activity: Running(
      ActiveRun(..active, round:, phase: AwaitingInference(operation)),
    ),
  )
}

fn handle_inference_event(
  runtime_state: RuntimeState,
  run_id: String,
  round: Int,
  inference_event: provider.InferenceEvent,
) -> RuntimeState {
  case runtime_state.activity {
    Running(active) if active.id == run_id ->
      case active.phase {
        AwaitingInference(operation) if operation.round == round ->
          case inference_event {
            provider.Delta(delta) -> {
              process.send(
                active.sink,
                agent_run.InferenceDelta(round:, delta:),
              )
              runtime_state
            }
            provider.Finished(result) ->
              finish_inference(runtime_state, active, operation, result)
          }
        _ -> runtime_state
      }
    _ -> runtime_state
  }
}

fn finish_inference(
  runtime_state: RuntimeState,
  active: ActiveRun,
  operation: InferenceOperation,
  inference_result: Result(provider.InferenceResult, AiError),
) -> RuntimeState {
  process.send(
    active.sink,
    agent_run.InferenceFinished(
      round: operation.round,
      result: inference_result,
    ),
  )
  let duration = events.system_time() - operation.started_at
  case inference_result {
    Ok(result) -> {
      let metadata = result.metadata
      let response_model = case metadata.response_model {
        option.Some(_) as model -> model
        option.None -> option.Some(runtime_state.config.model)
      }
      emit.to_dispatcher(
        runtime_state.config.dispatcher,
        events.InferenceCompleted(
          message: result.message,
          response_id: metadata.response_id,
          response_model:,
          stop_reason: metadata.stop_reason,
          input_tokens: metadata.input_tokens,
          output_tokens: metadata.output_tokens,
          duration_ms: duration,
          input_messages: operation.input_messages,
          settings: operation.settings,
        ),
      )
      hooks.notify_after_inference(
        runtime_state.config.hooks,
        hooks.AfterInferenceEvent(
          model: runtime_state.config.model,
          message: result.message,
          duration_ms: duration,
          settings: operation.settings,
        ),
      )
      let ready =
        ActiveRun(
          ..active,
          phase: Preparing,
          last_inference: option.Some(result),
        )
      advance(
        RuntimeState(..runtime_state, activity: Running(ready)),
        msg.ProviderResponded(Ok(result.message)),
      )
    }
    Error(error) -> {
      emit_inference_failure(runtime_state, operation, error, duration)
      let ready = ActiveRun(..active, phase: Preparing)
      advance(
        RuntimeState(..runtime_state, activity: Running(ready)),
        msg.ProviderResponded(Error(error)),
      )
    }
  }
}

fn emit_inference_failure(
  runtime_state: RuntimeState,
  operation: InferenceOperation,
  error: AiError,
  duration_ms: Int,
) -> Nil {
  emit.to_dispatcher(
    runtime_state.config.dispatcher,
    events.InferenceFailed(
      model: runtime_state.config.model,
      error:,
      duration_ms:,
      input_messages: operation.input_messages,
      settings: operation.settings,
    ),
  )
  hooks.notify_error(
    runtime_state.config.hooks,
    hooks.ErrorEvent(
      model: runtime_state.config.model,
      error:,
      settings: operation.settings,
    ),
  )
}

fn start_tools(
  runtime_state: RuntimeState,
  calls: List(ToolCall),
) -> RuntimeState {
  case execution.validate_tool_calls(calls) {
    Error(batch_error) -> {
      let rejected =
        list.map(calls, fn(call) {
          #(call, Error(tool.InvalidToolCallBatch(batch_error)))
        })
      advance(runtime_state, msg.ToolResults(rejected))
    }
    Ok(Nil) -> start_valid_tools(runtime_state, calls)
  }
}

fn start_valid_tools(
  runtime_state: RuntimeState,
  calls: List(ToolCall),
) -> RuntimeState {
  let assert Running(active) = runtime_state.activity
  let #(blocked, allowed) =
    tool_batch.partition_by_hook_decision(runtime_state.config.hooks, calls)
  let blocked_outcomes =
    list.map(blocked, fn(blocked_tool) {
      emit.to_dispatcher(
        runtime_state.config.dispatcher,
        events.ToolBlocked(
          tool_call: blocked_tool.call,
          hook_name: blocked_tool.hook_name,
          reason: blocked_tool.reason,
        ),
      )
      emit.to_dispatcher(
        runtime_state.config.dispatcher,
        events.HookActed(
          hook_name: blocked_tool.hook_name,
          hook_point: events.BeforeToolCall,
          action: events.HookActionDetail(
            action_type: "block",
            description: "Blocked tool: " <> blocked_tool.reason,
          ),
        ),
      )
      process.send(
        active.sink,
        agent_run.ToolBlocked(
          round: active.round,
          call: blocked_tool.call,
          reason: blocked_tool.reason,
        ),
      )
      tool_batch.ToolOutcome(
        call: blocked_tool.call,
        result: Error(tool.ToolError(
          message: "Tool blocked by '"
          <> blocked_tool.hook_name
          <> "': "
          <> blocked_tool.reason,
        )),
        duration_ms: 0,
      )
    })
  let mailbox = runtime_mailbox(runtime_state)
  let active_tools =
    list.map(allowed, fn(call) {
      emit.to_dispatcher(
        runtime_state.config.dispatcher,
        events.ToolStarted(tool_call: call),
      )
      process.send(
        active.sink,
        agent_run.ToolStarted(round: active.round, call:),
      )
      let run_id = active.id
      let round = active.round
      let started_at = events.system_time()
      let worker =
        tool_worker.start(
          runtime_state.config.tools,
          call,
          fn(result, duration_ms) {
            process.send(
              mailbox,
              ToolWorkerFinished(run_id, round, call, result, duration_ms),
            )
          },
        )
      tool_batch.ActiveTool(call:, worker:, started_at:)
    })
  case active_tools {
    [] ->
      advance(
        runtime_state,
        msg.ToolResults(tool_batch.ordered_results(calls, blocked_outcomes)),
      )
    _ ->
      RuntimeState(
        ..runtime_state,
        activity: Running(
          ActiveRun(
            ..active,
            phase: AwaitingTools(tool_batch.ToolBatch(
              round: active.round,
              calls:,
              active: active_tools,
              outcomes: blocked_outcomes,
            )),
          ),
        ),
      )
  }
}

fn handle_tool_finished(
  runtime_state: RuntimeState,
  run_id: String,
  round: Int,
  call: ToolCall,
  tool_result: Result(json.Json, tool.ToolError),
  duration_ms: Int,
) -> RuntimeState {
  case runtime_state.activity {
    Running(active) if active.id == run_id ->
      handle_active_tool_finished(
        runtime_state,
        active,
        round,
        call,
        tool_result,
        duration_ms,
      )
    _ -> runtime_state
  }
}

fn handle_active_tool_finished(
  runtime_state: RuntimeState,
  active: ActiveRun,
  round: Int,
  call: ToolCall,
  tool_result: Result(json.Json, tool.ToolError),
  duration_ms: Int,
) -> RuntimeState {
  case active.phase {
    AwaitingTools(batch) if batch.round == round ->
      finish_active_tool(
        runtime_state,
        active,
        batch,
        round,
        call,
        tool_result,
        duration_ms,
      )
    _ -> runtime_state
  }
}

fn finish_active_tool(
  runtime_state: RuntimeState,
  active: ActiveRun,
  batch: tool_batch.ToolBatch,
  round: Int,
  call: ToolCall,
  tool_result: Result(json.Json, tool.ToolError),
  duration_ms: Int,
) -> RuntimeState {
  case tool_batch.finish(batch, call, tool_result, duration_ms) {
    tool_batch.Ignored -> runtime_state
    tool_batch.Finished(outcomes) -> {
      observe_tool_result(
        runtime_state,
        active,
        round,
        call,
        tool_result,
        duration_ms,
      )
      let ready = ActiveRun(..active, phase: Preparing)
      advance(
        RuntimeState(..runtime_state, activity: Running(ready)),
        msg.ToolResults(tool_batch.ordered_results(batch.calls, outcomes)),
      )
    }
    tool_batch.Waiting(next_batch) -> {
      observe_tool_result(
        runtime_state,
        active,
        round,
        call,
        tool_result,
        duration_ms,
      )
      RuntimeState(
        ..runtime_state,
        activity: Running(ActiveRun(..active, phase: AwaitingTools(next_batch))),
      )
    }
  }
}

fn observe_tool_result(
  runtime_state: RuntimeState,
  active: ActiveRun,
  round: Int,
  call: ToolCall,
  tool_result: Result(json.Json, tool.ToolError),
  duration_ms: Int,
) -> Nil {
  let raw_content = tool_batch.result_content(tool_result)
  let hook_event =
    hooks.ToolResultEvent(
      tool_name: call.name,
      tool_call_id: call.id,
      result: raw_content,
      is_error: tool_batch.is_error(tool_result),
      duration_ms:,
    )
  let final_content = case
    hooks.decide_tool_result(runtime_state.config.hooks, hook_event)
  {
    hooks.ResultUnchanged(..) -> raw_content
    hooks.ResultTransformed(final_event:, transformers:) -> {
      emit_hook_acted_list(
        runtime_state.config.dispatcher,
        transformers,
        events.AfterToolCall,
        "transform",
        "Transformed result",
      )
      final_event.result
    }
  }
  emit.to_dispatcher(
    runtime_state.config.dispatcher,
    events.ToolExecuted(tool_call: call, result: final_content, duration_ms:),
  )
  process.send(
    active.sink,
    agent_run.ToolFinished(round:, call:, result: tool_result),
  )
}

fn resume_from_history(runtime_state: RuntimeState) -> RuntimeState {
  apply_recovery_action(
    runtime_state,
    run_recovery.from_history(runtime_state.agent_state),
  )
}

fn resume_disposition(
  runtime_state: RuntimeState,
  disposition: durable_session.PostCommitDisposition,
) -> RuntimeState {
  apply_recovery_action(
    runtime_state,
    run_recovery.from_disposition(disposition),
  )
}

fn apply_recovery_action(
  runtime_state: RuntimeState,
  action: run_recovery.RecoveryAction,
) -> RuntimeState {
  case action {
    run_recovery.Resume -> resume_from_history(runtime_state)
    run_recovery.StartInference ->
      start_inference(
        runtime_state,
        state.messages_for_provider(runtime_state.agent_state),
        state.tool_definitions(runtime_state.agent_state),
      )
    run_recovery.StartTools(calls) -> start_tools(runtime_state, calls)
    run_recovery.Complete(message) -> complete_run(runtime_state, message)
    run_recovery.Fail(error) -> fail_run(runtime_state, error)
  }
}

fn complete_run(runtime_state: RuntimeState, message: Message) -> RuntimeState {
  let assert Running(active) = runtime_state.activity
  let result = run_recovery.completion_result(active.last_inference, message)
  finish_terminal(runtime_state, run_recovery.Completed(result))
}

fn fail_run(
  runtime_state: RuntimeState,
  error: run_error.RunError,
) -> RuntimeState {
  finish_terminal(runtime_state, run_recovery.TermFailed(error))
}

fn finish_terminal(
  runtime_state: RuntimeState,
  terminal: run_recovery.Terminal,
) -> RuntimeState {
  let assert Running(active) = runtime_state.activity
  let event = case terminal {
    run_recovery.Completed(result) -> agent_run.Completed(result)
    run_recovery.TermFailed(error) -> agent_run.Failed(error)
    run_recovery.TermCancelled(reason) -> agent_run.Cancelled(reason)
  }
  agent_run.publish_terminal(active.run, event)
  run_recovery.notify_terminal(
    terminal,
    runtime_state.config.hooks,
    runtime_state.config.model,
    runtime_state.agent_state.iterations,
    active.sink,
  )
  client_watcher.stop_option(active.watcher)
  RuntimeState(..runtime_state, activity: Idle)
}

fn cancel_matching_run(
  runtime_state: RuntimeState,
  run_id: String,
  reason: run_error.CancelReason,
) -> RuntimeState {
  case runtime_state.activity {
    Running(active) if active.id == run_id ->
      cancel_current_run(runtime_state, reason)
    _ -> runtime_state
  }
}

fn cancel_current_run(
  runtime_state: RuntimeState,
  reason: run_error.CancelReason,
) -> RuntimeState {
  case runtime_state.activity {
    Idle -> runtime_state
    Running(active) -> {
      case active.phase {
        Preparing -> Nil
        AwaitingInference(operation) -> {
          inference_worker.cancel(operation.worker)
          process.send(
            active.sink,
            agent_run.InferenceFinished(
              round: operation.round,
              result: Error(error.Cancelled),
            ),
          )
          emit_inference_failure(
            runtime_state,
            operation,
            error.Cancelled,
            events.system_time() - operation.started_at,
          )
        }
        AwaitingTools(batch) ->
          list.each(batch.active, fn(active_tool) {
            tool_worker.cancel(active_tool.worker)
            let cancelled = Error(tool.Cancelled)
            observe_tool_result(
              runtime_state,
              active,
              batch.round,
              active_tool.call,
              cancelled,
              events.system_time() - active_tool.started_at,
            )
          })
      }
      finish_terminal(runtime_state, run_recovery.TermCancelled(reason))
    }
  }
}

fn emit_hook_acted_list(
  dispatcher_subject: process.Subject(dispatcher.DispatcherMessage),
  transformer_names: List(String),
  hook_point: events.HookPoint,
  action_type: String,
  description: String,
) -> Nil {
  list.each(transformer_names, fn(name) {
    emit.to_dispatcher(
      dispatcher_subject,
      events.HookActed(
        hook_name: name,
        hook_point:,
        action: events.HookActionDetail(action_type:, description:),
      ),
    )
  })
}

fn commit_transition(
  session: durable_session.SessionState,
  previous: state.AgentState,
  candidate: state.AgentState,
  disposition: durable_session.PostCommitDisposition,
) -> Result(
  durable_session.SessionState,
  #(durable_session.SessionState, session_store.SessionError),
) {
  let result =
    durable_session.commit_transition(session, previous, candidate, disposition)
  case result {
    Ok(next_session) -> Ok(next_session)
    Error(#(pending, error)) -> Error(#(pending, error))
  }
}

fn retry_pending_commit(
  pending: durable_session.SessionState,
) -> Result(
  #(
    state.AgentState,
    durable_session.SessionState,
    durable_session.PostCommitDisposition,
  ),
  #(durable_session.SessionState, session_store.SessionError),
) {
  case durable_session.retry_pending(pending) {
    Error(#(still_pending, error)) -> Error(#(still_pending, error))
    Ok(#(candidate, ready, disposition)) -> Ok(#(candidate, ready, disposition))
  }
}

fn set_runtime_settings(
  runtime_state: RuntimeState,
  settings: InferenceSettings,
) -> #(RuntimeState, Result(Nil, run_error.RunError)) {
  case runtime_state.activity {
    Running(_) -> #(
      runtime_state,
      Error(run_error.Runtime(
        "cannot change settings while an agent run is active",
      )),
    )
    Idle ->
      apply_durable_settings(runtime_state, runtime_state.session, settings)
  }
}

fn apply_durable_settings(
  runtime_state: RuntimeState,
  session: durable_session.SessionState,
  settings: InferenceSettings,
) -> #(RuntimeState, Result(Nil, run_error.RunError)) {
  apply_settings_result(
    runtime_state,
    durable_session.set_settings(
      session,
      runtime_state.agent_state,
      runtime_state.config.inference_settings,
      settings,
    ),
  )
}

fn apply_settings_result(
  runtime_state: RuntimeState,
  settings_result: durable_session.SettingsResult,
) -> #(RuntimeState, Result(Nil, run_error.RunError)) {
  let durable_session.SettingsResult(
    session:,
    agent_state:,
    inference_settings:,
    outcome:,
    rejection:,
  ) = settings_result
  let next_state =
    RuntimeState(..runtime_state, agent_state:, session:, inference_settings:)
  let result = case rejection {
    option.Some(durable_session.CommitPending) ->
      Error(run_error.Runtime(
        "cannot change settings while a session commit is pending",
      ))
    option.Some(durable_session.DifferentSettingsPending) ->
      Error(run_error.Runtime(
        "a different inference settings commit is pending",
      ))
    option.None ->
      case outcome {
        Ok(Nil) -> Ok(Nil)
        Error(error) -> Error(run_error.Session(error))
      }
  }
  #(next_state, result)
}

fn to_durable_session(session: SessionState) -> durable_session.SessionState {
  case session {
    SessionDisabled -> durable_session.SessionDisabled
    SessionReady(store:, head:) -> durable_session.SessionReady(store:, head:)
    SessionPending(store:, commit:, candidate:, disposition:) ->
      durable_session.SessionPending(store:, commit:, candidate:, disposition:)
    SessionSettingsPending(store:, settings:, mode:) ->
      durable_session.SessionSettingsPending(store:, settings:, mode:)
  }
}
