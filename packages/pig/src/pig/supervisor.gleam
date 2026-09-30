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
import gleam/string
import logging
import pig/agent/runtime
import pig/agent/state
import pig/obs/consumer_spec
import pig/obs/dispatcher
import pig/provider.{type InferenceSettings}
import pig/run as agent_run
import pig/run_error.{type CancelReason, type RunError, type RunStartError}
import pig/session_store.{type SessionError, type SessionStore, SessionStore}
import pig/turn.{type Input}
import pig_otel
import pig_protocol/message.{type Message}
import pig_protocol/thinking.{type ThinkingLevel}

/// Handle to a supervised agent.
///
/// Wraps the agent's `Subject` and the supervisor's `Pid`.
/// Use `run`/`run_with_timeout` to send prompts, `stop` to
/// tear down the supervision tree.
pub type SupervisedAgent {
  SupervisedAgent(
    subject: Subject(runtime.RuntimeMsg),
    sup_pid: Pid,
    dispatcher: Subject(dispatcher.DispatcherMessage),
  )
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
  start_supervised_with_tracing(
    agent_config,
    consumer_specs,
    pig_otel.MetadataOnly,
  )
}

/// Start a supervised agent with an explicit tracing policy.
pub fn start_supervised_with_tracing(
  agent_config: state.AgentConfig,
  consumer_specs: List(consumer_spec.ConsumerSpec),
  tracing: pig_otel.Policy,
) -> Result(SupervisedAgent, StartError) {
  start_with_session(
    agent_config,
    consumer_specs,
    [],
    runtime.SessionDisabled,
    tracing,
  )
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
  start_supervised_with_session_store_and_tracing(
    agent_config,
    consumer_specs,
    store,
    pig_otel.MetadataOnly,
  )
}

/// Start a durable supervised agent with an explicit tracing policy.
pub fn start_supervised_with_session_store_and_tracing(
  agent_config: state.AgentConfig,
  consumer_specs: List(consumer_spec.ConsumerSpec),
  store: SessionStore,
  tracing: pig_otel.Policy,
) -> Result(SupervisedAgent, StartError) {
  let SessionStore(load:, ..) = store
  case load() {
    Error(error) -> Error(SessionLoad(error))
    Ok(_) ->
      start_with_runtime(consumer_specs, fn(dispatcher_name, name) {
        runtime.supervised_with_session_store_and_tracing(
          agent_config,
          dispatcher_name,
          name,
          store,
          tracing,
        )
      })
  }
}

fn start_with_session(
  agent_config: state.AgentConfig,
  consumer_specs: List(consumer_spec.ConsumerSpec),
  initial_history: List(Message),
  session: runtime.SessionState,
  tracing: pig_otel.Policy,
) -> Result(SupervisedAgent, StartError) {
  start_with_runtime(consumer_specs, fn(dispatcher_name, name) {
    runtime.supervised_with_tracing(
      agent_config,
      dispatcher_name,
      name,
      initial_history,
      session,
      tracing,
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
  let consumer_endpoints =
    list.map(consumer_specs, fn(entry) {
      consumer_spec.supervised_endpoint_for(entry)
    })
  let event_tree =
    static_supervisor.new(static_supervisor.OneForAll)
    |> static_supervisor.add(dispatcher.supervised_with_consumers(
      dispatcher_name,
      consumer_endpoints,
    ))
    |> list.fold(consumer_specs, _, fn(builder, entry) {
      static_supervisor.add(builder, consumer_spec.child_spec(entry))
    })

  // Build top-level: event subtree (as supervised child) → agent
  let app_tree =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(static_supervisor.supervised(event_tree))
    |> static_supervisor.add(runtime_spec(dispatcher_name, agent_name))

  case static_supervisor.start(app_tree) {
    Ok(started) -> {
      let agent_subject = process.named_subject(agent_name)
      Ok(SupervisedAgent(
        subject: agent_subject,
        sup_pid: started.pid,
        dispatcher: process.named_subject(dispatcher_name),
      ))
    }
    Error(e) -> Error(ActorStart(e))
  }
}

/// Start one streamed run on the supervised agent.
pub fn stream(
  sup: SupervisedAgent,
  prompt: String,
  sink: Subject(agent_run.RunEvent),
) -> Result(agent_run.Run, RunStartError) {
  stream_turn(sup, turn.User(prompt), sink)
}

/// Start one streamed run with an explicit client owner.
pub fn stream_owned(
  sup: SupervisedAgent,
  prompt: String,
  sink: Subject(agent_run.RunEvent),
  owner: Pid,
) -> Result(agent_run.Run, RunStartError) {
  stream_turn_owned(sup, turn.User(prompt), sink, owner)
}

/// Start one typed turn on the supervised agent.
pub fn stream_turn(
  sup: SupervisedAgent,
  input: Input,
  sink: Subject(agent_run.RunEvent),
) -> Result(agent_run.Run, RunStartError) {
  runtime.stream_turn(sup.subject, input, sink)
}

/// Start one typed turn while watching an explicit client owner.
pub fn stream_turn_owned(
  sup: SupervisedAgent,
  input: Input,
  sink: Subject(agent_run.RunEvent),
  owner: Pid,
) -> Result(agent_run.Run, RunStartError) {
  runtime.stream_turn_owned(sup.subject, input, sink, owner)
}

/// Resume history as one streamed run.
pub fn stream_continue(
  sup: SupervisedAgent,
  sink: Subject(agent_run.RunEvent),
) -> Result(agent_run.Run, RunStartError) {
  runtime.stream_continue(sup.subject, sink)
}

/// Resume history as a streamed run with an explicit client owner.
pub fn stream_continue_owned(
  sup: SupervisedAgent,
  sink: Subject(agent_run.RunEvent),
  owner: Pid,
) -> Result(agent_run.Run, RunStartError) {
  runtime.stream_continue_owned(sup.subject, sink, owner)
}

/// Cancel a supervised run. Repeated calls are harmless.
pub fn cancel(run: agent_run.Run, reason: CancelReason) -> Nil {
  agent_run.cancel(run, reason)
}

/// Run a prompt against the supervised agent with a 120-second timeout.
pub fn run(sup: SupervisedAgent, prompt: String) -> Result(Message, RunError) {
  run_turn(sup, turn.User(prompt))
}

/// Run a prompt against the supervised agent with an explicit timeout.
pub fn run_with_timeout(
  sup: SupervisedAgent,
  prompt: String,
  timeout_ms: Int,
) -> Result(Message, RunError) {
  runtime.run_turn(sup.subject, turn.User(prompt), timeout_ms)
}

/// Run one typed turn with the default 120-second timeout.
pub fn run_turn(
  sup: SupervisedAgent,
  input: Input,
) -> Result(Message, RunError) {
  run_turn_with_timeout(sup, input, 120_000)
}

/// Run one typed turn with an explicit timeout.
pub fn run_turn_with_timeout(
  sup: SupervisedAgent,
  input: Input,
  timeout_ms: Int,
) -> Result(Message, RunError) {
  runtime.run_turn(sup.subject, input, timeout_ms)
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
  runtime.stop(sup.subject)
  case dispatcher.shutdown(sup.dispatcher) {
    Ok(Nil) -> Nil
    Error(error) ->
      logging.log(
        logging.Warning,
        "Supervised agent shutdown did not drain consumers: "
          <> string.inspect(error),
      )
  }
  process.send_exit(sup.sup_pid)
}
