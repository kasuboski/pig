//// Supervised agent — wraps agent in OTP static supervisor.
////
//// The easy path: `start_supervised(config)` gives you an agent
//// managed by a OneForOne supervisor. Advanced users can still
//// use `pig.start(config)` for standalone agents.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/otp/actor.{type StartError as ActorStartError}
import gleam/otp/static_supervisor
import gleam/otp/supervision
import pig/agent/runtime
import pig/agent/state
import pig/obs/consumer_spec
import pig/obs/dispatcher
import pig/provider.{type InferenceSettings}
import pig/run_error.{type RunError}
import pig/session_store.{type SessionError, type SessionStore, SessionStore}
import pig_protocol/message.{type Message}
import pig_protocol/thinking.{type ThinkingLevel}

/// Handle to a supervised agent.
///
/// Wraps the agent's `Subject` and the supervisor's `Pid`.
/// Use `run`/`run_with_timeout` to send prompts, `stop` to
/// tear down the supervision tree.
pub type SupervisedAgent {
  SupervisedAgent(subject: Subject(runtime.RuntimeMsg), sup_pid: Pid)
}

/// Errors that can prevent a supervised agent from starting.
pub type StartError {
  /// The OTP supervision tree or one of its children could not start.
  ActorStart(error: ActorStartError)
  /// The durable session could not be loaded before the tree was started.
  SessionLoad(error: SessionError)
}

/// Start a supervised agent without durable session storage.
///
/// This convenience path starts with empty history and no durable session.
pub fn start_supervised(
  agent_config: state.AgentConfig,
  consumer_specs: List(consumer_spec.ConsumerSpec),
) -> Result(SupervisedAgent, StartError) {
  start_with_session(agent_config, consumer_specs, [], runtime.SessionDisabled)
}

/// Preflight a durable session, then start a supervised agent.
///
/// The preflight preserves a typed `SessionLoad` error without starting the
/// supervision tree. The runtime independently reloads the store every time
/// its worker starts, including after OTP child restarts.
pub fn start_supervised_with_session_store(
  agent_config: state.AgentConfig,
  consumer_specs: List(consumer_spec.ConsumerSpec),
  store: SessionStore,
) -> Result(SupervisedAgent, StartError) {
  let SessionStore(load:, ..) = store
  case load() {
    Error(error) -> Error(SessionLoad(error))
    Ok(_) ->
      start_with_runtime(consumer_specs, fn(dispatcher_name, name) {
        runtime.supervised_with_session_store(
          agent_config,
          dispatcher_name,
          name,
          store,
        )
      })
  }
}

fn start_with_session(
  agent_config: state.AgentConfig,
  consumer_specs: List(consumer_spec.ConsumerSpec),
  initial_history: List(Message),
  session: runtime.SessionState,
) -> Result(SupervisedAgent, StartError) {
  start_with_runtime(consumer_specs, fn(dispatcher_name, name) {
    runtime.supervised(
      agent_config,
      dispatcher_name,
      name,
      initial_history,
      session,
    )
  })
}

fn start_with_runtime(
  consumer_specs: List(consumer_spec.ConsumerSpec),
  runtime_spec: fn(
    process.Name(dispatcher.DispatcherMessage),
    process.Name(runtime.RuntimeMsg),
  ) -> supervision.ChildSpecification(Nil),
) -> Result(SupervisedAgent, StartError) {
  let dispatcher_name = process.new_name("pig_event_dispatcher")
  let agent_name = process.new_name("pig_agent")

  // Build event subtree: dispatcher + consumers.
  // OneForAll ensures that if either side restarts, the named subjects still
  // point at the reconstructed consumers and dispatcher.
  let consumer_subjects =
    list.map(consumer_specs, fn(entry) { process.named_subject(entry.name) })
  let event_tree =
    static_supervisor.new(static_supervisor.OneForAll)
    |> static_supervisor.add(dispatcher.supervised_with_consumers(
      dispatcher_name,
      consumer_subjects,
    ))
    |> list.fold(consumer_specs, _, fn(builder, entry) {
      static_supervisor.add(builder, entry.spec)
    })

  // Build top-level: event subtree (as supervised child) → agent
  let app_tree =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(static_supervisor.supervised(event_tree))
    |> static_supervisor.add(runtime_spec(dispatcher_name, agent_name))

  case static_supervisor.start(app_tree) {
    Ok(started) -> {
      let agent_subject = process.named_subject(agent_name)
      Ok(SupervisedAgent(subject: agent_subject, sup_pid: started.pid))
    }
    Error(e) -> Error(ActorStart(e))
  }
}

/// Run a prompt against the supervised agent with a 120-second timeout.
pub fn run(sup: SupervisedAgent, prompt: String) -> Result(Message, RunError) {
  run_with_timeout(sup, prompt, 120_000)
}

/// Run a prompt against the supervised agent with an explicit timeout.
pub fn run_with_timeout(
  sup: SupervisedAgent,
  prompt: String,
  timeout_ms: Int,
) -> Result(Message, RunError) {
  runtime.run(sup.subject, prompt, timeout_ms)
}

/// Resume a supervised agent's loaded or interrupted history.
pub fn run_continue(sup: SupervisedAgent) -> Result(Message, RunError) {
  run_continue_with_timeout(sup, 120_000)
}

/// Resume a supervised agent's history with an explicit timeout.
pub fn run_continue_with_timeout(
  sup: SupervisedAgent,
  timeout_ms: Int,
) -> Result(Message, RunError) {
  runtime.run_continue(sup.subject, timeout_ms)
}

/// Set inference settings on the supervised agent.
pub fn set_inference_settings(
  sup: SupervisedAgent,
  settings: InferenceSettings,
) -> Result(Nil, RunError) {
  set_inference_settings_with_timeout(sup, settings, 120_000)
}

/// Set inference settings on the supervised agent with an explicit timeout.
pub fn set_inference_settings_with_timeout(
  sup: SupervisedAgent,
  settings: InferenceSettings,
  timeout_ms: Int,
) -> Result(Nil, RunError) {
  runtime.set_inference_settings(sup.subject, settings, timeout_ms)
}

/// Set the thinking level on the supervised agent.
pub fn set_thinking_level(
  sup: SupervisedAgent,
  level: ThinkingLevel,
) -> Result(Nil, RunError) {
  set_inference_settings(sup, provider.with_thinking_level(level))
}

/// Reset the supervised agent to the provider's default thinking behavior.
pub fn reset_inference_settings(sup: SupervisedAgent) -> Result(Nil, RunError) {
  set_inference_settings(sup, provider.default_settings())
}

/// Stop the supervised agent.
///
/// Sends an exit signal to the supervisor process. OTP cascades
/// shutdown to the agent child process.
pub fn stop(sup: SupervisedAgent) -> Nil {
  process.send_exit(sup.sup_pid)
}
