//// Supervised agent — wraps agent in OTP static supervisor.
////
//// The easy path: `start_supervised(config)` gives you an agent
//// managed by a OneForOne supervisor. Advanced users can still
//// use `pig.start(config)` for standalone agents.

import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/otp/actor as otp_actor
import gleam/otp/static_supervisor
import pig/agent/runtime
import pig/agent/state
import pig/ai/error.{type AiError}
import pig/ai/message.{type Message}
import pig/obs/consumer_spec
import pig/obs/dispatcher

/// Handle to a supervised agent.
///
/// Wraps the agent's `Subject` and the supervisor's `Pid`.
/// Use `run`/`run_with_timeout` to send prompts, `stop` to
/// tear down the supervision tree.
pub type SupervisedAgent {
  SupervisedAgent(subject: Subject(runtime.RuntimeMsg), sup_pid: Pid)
}

/// Start a supervised agent from an AgentConfig and consumer specs.
///
/// Spawns a nested OneForOne static supervisor containing:
/// - An event subtree (dispatcher + consumers)
/// - The agent actor
///
/// The dispatcher and agent are named so Subjects can be recovered after
/// supervisor start. Returns a `SupervisedAgent` handle.
pub fn start_supervised(
  agent_config: state.AgentConfig,
  consumer_specs: List(consumer_spec.ConsumerSpec),
) -> Result(SupervisedAgent, otp_actor.StartError) {
  let dispatcher_name = process.new_name("pig_event_dispatcher")
  let agent_name = process.new_name("pig_agent")

  // Build event subtree: dispatcher + consumers
  // OneForAll ensures that if the dispatcher restarts, consumers restart too
  // and re-register via their init logic.
  let event_tree =
    static_supervisor.new(static_supervisor.OneForAll)
    |> static_supervisor.add(dispatcher.supervised(dispatcher_name))
    |> list.fold(consumer_specs, _, fn(builder, entry) {
      static_supervisor.add(builder, entry.spec)
    })

  // Build top-level: event subtree (as supervised child) → agent
  let app_tree =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(static_supervisor.supervised(event_tree))
    |> static_supervisor.add(runtime.supervised(
      agent_config,
      dispatcher_name,
      agent_name,
    ))

  case static_supervisor.start(app_tree) {
    Ok(started) -> {
      let dispatcher_subject = process.named_subject(dispatcher_name)
      let agent_subject = process.named_subject(agent_name)

      // Register all consumers with the dispatcher
      list.each(consumer_specs, fn(entry) {
        let consumer_subject = process.named_subject(entry.name)
        process.send(
          dispatcher_subject,
          dispatcher.RegisterConsumer(consumer_subject),
        )
      })

      Ok(SupervisedAgent(subject: agent_subject, sup_pid: started.pid))
    }
    Error(e) -> Error(e)
  }
}

/// Run a prompt against the supervised agent with a 30-second timeout.
pub fn run(sup: SupervisedAgent, prompt: String) -> Result(Message, AiError) {
  run_with_timeout(sup, prompt, 30_000)
}

/// Run a prompt against the supervised agent with an explicit timeout.
pub fn run_with_timeout(
  sup: SupervisedAgent,
  prompt: String,
  timeout_ms: Int,
) -> Result(Message, AiError) {
  runtime.run(sup.subject, prompt, timeout_ms)
}

/// Stop the supervised agent.
///
/// Sends an exit signal to the supervisor process. OTP cascades
/// shutdown to the agent child process.
pub fn stop(sup: SupervisedAgent) -> Nil {
  process.send_exit(sup.sup_pid)
}
