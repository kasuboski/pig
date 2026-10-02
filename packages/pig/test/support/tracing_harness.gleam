//// Centralized boundary harness: real runtime/provider/tool OTP handoffs,
//// deterministic API recording, and explicit gates instead of sleeps.

import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import otel/context
import pig
import pig/agent/runtime
import pig/agent/state
import pig/hooks
import pig/obs/dispatcher
import pig/provider
import pig/run
import pig/run_error
import pig/session_store
import pig/session_store/memory
import pig/supervisor
import pig/tool
import pig/turn
import pig_otel
import pig_protocol/message

pub type Snapshot {
  Snapshot(
    id: String,
    name: String,
    parent: String,
    attributes: List(#(String, String)),
    status: String,
    ends: Int,
  )
}

pub type Agent {
  Direct(pig.Agent)
  Supervised(supervisor.SupervisedAgent)
}

/// Every public entry family uses the same harness setup and terminal cleanup.
pub fn check_agent(
  provider: provider.Provider,
  tools: List(tool.Tool),
  hooks: List(hooks.Hooks),
  policy: pig_otel.Policy,
  supervised: Bool,
  work: fn(Agent) -> a,
) -> a {
  check_agent_using(
    setup,
    provider,
    tools,
    hooks,
    option.None,
    policy,
    supervised,
    work,
  )
}

pub fn check_agent_with_system_prompt(
  provider: provider.Provider,
  tools: List(tool.Tool),
  hooks: List(hooks.Hooks),
  system_prompt: String,
  policy: pig_otel.Policy,
  work: fn(Agent) -> a,
) -> a {
  check_agent_using(
    setup,
    provider,
    tools,
    hooks,
    option.Some(system_prompt),
    policy,
    False,
    work,
  )
}

/// Start one fully built public config through either supported agent entrypoint.
pub fn check_config(
  config: pig.PigConfig,
  policy: pig_otel.Policy,
  supervised: Bool,
  work: fn(Agent) -> a,
) -> a {
  setup()
  let agent = case supervised {
    False -> {
      let assert Ok(agent) = pig.start(pig.with_tracing(config, policy))
      Direct(agent)
    }
    True -> {
      let agent_config = pig.build_agent_config(config)
      let assert Ok(agent) =
        supervisor.start_supervised_with_tracing(agent_config, [], policy)
      Supervised(agent)
    }
  }
  finally(fn() { work(agent) }, fn() {
    stop(agent)
    teardown()
  })
}

/// Exercise metadata-only defaults against the API with no tracer provider/SDK.
pub fn check_no_sdk(provider: provider.Provider, work: fn(Agent) -> a) -> a {
  check_no_sdk_with_policy(provider, pig_otel.MetadataOnly, work)
}

pub fn check_no_sdk_with_policy(
  provider: provider.Provider,
  policy: pig_otel.Policy,
  work: fn(Agent) -> a,
) -> a {
  check_agent_using(
    no_sdk_setup,
    provider,
    [],
    [],
    option.None,
    policy,
    False,
    work,
  )
}

fn check_agent_using(
  setup: fn() -> Nil,
  provider: provider.Provider,
  tools: List(tool.Tool),
  hooks: List(hooks.Hooks),
  system_prompt: option.Option(String),
  policy: pig_otel.Policy,
  supervised: Bool,
  work: fn(Agent) -> a,
) -> a {
  setup()
  let agent = case supervised {
    False -> {
      let config =
        pig.new(provider) |> pig.with_tools(tools) |> pig.with_tracing(policy)
      let config = case system_prompt {
        option.Some(prompt) -> pig.with_system_prompt(config, prompt)
        option.None -> config
      }
      let config = list.fold(hooks, config, pig.with_hooks)
      let assert Ok(agent) = pig.start(config)
      Direct(agent)
    }
    True -> {
      let config =
        state.config(provider)
        |> state.with_tools(list.fold(tools, tool.new_registry(), tool.register))
      let config = case system_prompt {
        option.Some(prompt) -> state.with_system_prompt(config, prompt)
        option.None -> config
      }
      let assert Ok(agent) =
        supervisor.start_supervised_with_tracing(config, [], policy)
      Supervised(agent)
    }
  }
  finally(fn() { work(agent) }, fn() {
    stop(agent)
    teardown()
  })
}

pub fn check_runtime(
  provider: provider.Provider,
  hooks: List(hooks.Hooks),
  session: runtime.SessionState,
  work: fn(process.Subject(runtime.RuntimeMsg)) -> a,
) -> a {
  check_runtime_with_tools(provider, [], hooks, session, work)
}

/// The same runtime boundary, with a registry for real parallel tool sources.
pub fn check_runtime_with_tools(
  provider: provider.Provider,
  tools: List(tool.Tool),
  hooks: List(hooks.Hooks),
  session: runtime.SessionState,
  work: fn(process.Subject(runtime.RuntimeMsg)) -> a,
) -> a {
  setup()
  let assert Ok(dispatcher) = dispatcher.start()
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let config =
    runtime.RuntimeConfig(
      provider:,
      tools: registry,
      hooks:,
      dispatcher:,
      model: "agent-label-not-wire-model",
      max_iterations: 50,
      inference_settings: provider.default_settings(),
      tracing: pig_otel.MetadataOnly,
    )
  let initial =
    runtime.initial_state(
      state.new(state.config(provider) |> state.with_tools(registry)),
      config,
      session,
      config.inference_settings,
    )
  let assert Ok(subject) = runtime.start_with_state(config, initial)
  let assert Ok(owner) = process.subject_owner(subject)
  process.unlink(owner)
  finally(fn() { work(subject) }, fn() {
    // A crash regression already has its DOWN ACK; do not await a dead actor.
    case process.is_alive(owner) {
      True -> runtime.stop(subject)
      False -> Nil
    }
    process.send(dispatcher, dispatcher.Stop)
    teardown()
  })
}

pub fn stream(agent: Agent, sink: process.Subject(run.RunEvent)) -> run.Run {
  let assert Ok(handle) = case agent {
    Direct(agent) -> pig.stream_turn(agent, pig_turn(), sink)
    Supervised(agent) -> supervisor.stream_turn(agent, pig_turn(), sink)
  }
  handle
}

pub fn continue_run(
  agent: Agent,
  sink: process.Subject(run.RunEvent),
) -> run.Run {
  let assert Ok(handle) = case agent {
    Direct(agent) -> pig.stream_continue(agent, sink)
    Supervised(agent) -> supervisor.stream_continue(agent, sink)
  }
  handle
}

pub fn buffered(agent: Agent) -> Result(message.Message, run_error.RunError) {
  case agent {
    Direct(agent) -> pig.run(agent, "secret input")
    Supervised(agent) -> supervisor.run(agent, "secret input")
  }
}

pub fn start_again(agent: Agent) -> Result(run.Run, run_error.RunStartError) {
  let sink = process.new_subject()
  case agent {
    Direct(agent) -> pig.stream(agent, "busy", sink)
    Supervised(agent) -> supervisor.stream(agent, "busy", sink)
  }
}

pub fn stop(agent: Agent) -> Nil {
  case agent {
    Direct(agent) -> pig.stop(agent)
    Supervised(agent) -> supervisor.stop(agent)
  }
}

pub fn collect(
  handle: run.Run,
  sink: process.Subject(run.RunEvent),
) -> Result(message.Message, run_error.RunError) {
  run.collect(handle, sink, 5000, run.runtime_owner(handle))
}

pub fn await(subject: process.Subject(a)) -> a {
  let assert Ok(value) = process.receive(subject, 5000)
  value
}

/// ACK monitor installation before a test releases or cancels a callback gate.
/// Subjects identify their callback owner without exposing worker PIDs to tests.
pub fn watch_source(
  control: process.Subject(a),
) -> process.Subject(process.ExitReason) {
  let assert Ok(owner) = process.subject_owner(control)
  let ready = process.new_subject()
  let retired = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let monitor = process.monitor(owner)
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
      process.send(ready, Nil)
      let assert Ok(process.ProcessDown(_, _, reason)) =
        process.selector_receive(selector, 5000)
      process.send(retired, reason)
    })
  let _ = await(ready)
  retired
}

/// Drain only after a terminal/monitor or runtime reply establishes the boundary.
pub fn drain(subject: process.Subject(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(value) -> [value, ..drain(subject)]
    Error(Nil) -> []
  }
}

pub fn assistant() -> message.Message {
  message.Assistant("secret completion", [], option.None, option.None)
}

pub fn unavailable_store() -> session_store.SessionStore {
  session_store.SessionStore(
    load: fn() { Ok(session_store.Session(option.None, [], option.None)) },
    commit: fn(commit) {
      case commit.delta {
        session_store.MessagesAppended(message.User(_), _) ->
          Ok(session_store.Session(
            option.Some(commit.id),
            [message.User("secret input")],
            option.None,
          ))
        _ -> Error(session_store.Unavailable("secret database details"))
      }
    },
  )
}

fn pig_turn() -> turn.Input {
  turn.Developer("secret input")
}

@external(erlang, "pig_trace_test_ffi", "setup")
fn setup() -> Nil

@external(erlang, "pig_trace_test_ffi", "teardown")
fn teardown() -> Nil

@external(erlang, "pig_trace_test_ffi", "snapshot")
pub fn snapshot() -> List(Snapshot)

@external(erlang, "pig_trace_test_ffi", "current_id")
pub fn current_id() -> String

@external(erlang, "pig_trace_test_ffi", "context_id")
pub fn context_id(context: context.Context) -> String

@external(erlang, "pig_trace_test_ffi", "raised")
pub fn raised(work: fn() -> a) -> String

@external(erlang, "pig_trace_test_ffi", "exit_message")
pub fn exit_message(reason: process.ExitReason) -> String

@external(erlang, "pig_trace_test_ffi", "finally")
fn finally(work: fn() -> a, cleanup: fn() -> Nil) -> a

@external(erlang, "pig_trace_test_ffi", "double_failure")
pub fn double_failure() -> String

@external(erlang, "pig_trace_test_ffi", "no_sdk_setup")
fn no_sdk_setup() -> Nil

type CommitGate {
  Attempt(process.Subject(Bool))
  StopGate
}

/// A real durable store that rejects one assistant commit, then permits recovery.
pub fn recoverable_store() -> #(session_store.SessionStore, fn() -> Nil) {
  let assert Ok(memory) =
    memory.start(session_store.Session(option.None, [], option.None))
  let store = memory.store(memory)
  let assert Ok(gate) =
    actor.new(False)
    |> actor.on_message(fn(failed, message) {
      case message {
        Attempt(reply) -> {
          process.send(reply, failed)
          actor.continue(True)
        }
        StopGate -> actor.stop()
      }
    })
    |> actor.start
  let wrapped =
    session_store.SessionStore(load: store.load, commit: fn(commit) {
      case commit.delta {
        session_store.MessagesAppended(message.Assistant(..), _) -> {
          let failed = actor.call(gate.data, 5000, Attempt)
          case failed {
            False -> Error(session_store.Unavailable("secret database details"))
            True -> store.commit(commit)
          }
        }
        _ -> store.commit(commit)
      }
    })
  #(wrapped, fn() {
    memory.stop(memory)
    process.send(gate.data, StopGate)
  })
}
