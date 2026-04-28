//// Supervised agent — wraps agent in OTP static supervisor.
////
//// The easy path: `start_supervised(config)` gives you an agent
//// managed by a OneForOne supervisor. Advanced users can still
//// use `pig.start(config)` for standalone agents.
////


import gleam/erlang/process.{type Pid, type Subject}
import gleam/otp/actor as otp_actor
import gleam/otp/static_supervisor
import pig/agent/actor
import pig/agent/state
import pig/ai/error.{type AiError}
import pig/ai/message.{type Message}

/// Handle to a supervised agent.
///
/// Wraps the agent's `Subject` and the supervisor's `Pid`.
/// Use `run`/`run_with_timeout` to send prompts, `stop` to
/// tear down the supervision tree.
pub type SupervisedAgent {
  SupervisedAgent(
    subject: Subject(actor.AgentMessage),
    sup_pid: Pid,
  )
}

/// Start a supervised agent from an AgentConfig.
///
/// Spawns a OneForOne static supervisor containing the agent actor.
/// The actor is named so the Subject can be recovered after
/// supervisor start. Returns a `SupervisedAgent` handle.
pub fn start_supervised(
  agent_config: state.AgentConfig,
) -> Result(SupervisedAgent, otp_actor.StartError) {
  let name = process.new_name("pig_agent")
  let child_spec = actor.supervised(agent_config, name)
  let sup_builder =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child_spec)
  case static_supervisor.start(sup_builder) {
    Ok(started) -> {
      let subject = process.named_subject(name)
      Ok(SupervisedAgent(subject:, sup_pid: started.pid))
    }
    Error(e) -> Error(e)
  }
}

/// Run a prompt against the supervised agent with a 30-second timeout.
pub fn run(
  sup: SupervisedAgent,
  prompt: String,
) -> Result(Message, AiError) {
  run_with_timeout(sup, prompt, 30_000)
}

/// Run a prompt against the supervised agent with an explicit timeout.
pub fn run_with_timeout(
  sup: SupervisedAgent,
  prompt: String,
  timeout_ms: Int,
) -> Result(Message, AiError) {
  actor.run(sup.subject, prompt, timeout_ms)
}

/// Stop the supervised agent.
///
/// Sends an exit signal to the supervisor process. OTP cascades
/// shutdown to the agent child process.
pub fn stop(sup: SupervisedAgent) -> Nil {
  process.send_exit(sup.sup_pid)
}
