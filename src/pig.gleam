//// Top-level public API for the pig library.
////
//// Builder pattern: `new(provider) |> with_tool(t) |> with_skill(s) |> start`
//// Then: `run(agent, prompt)` or `run_with_timeout(agent, prompt, ms)`
////
//// Thin public surface. All logic in agent/update (pure core) +
//// agent/runtime (impure interpreter).

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option
import gleam/otp/actor.{type StartError}
import gleam/string
import logging
import pig/agent/runtime
import pig/agent/state
import pig/ai/error.{type AiError}
import pig/ai/message.{type Message}
import pig/ai/provider.{type Provider, from_message}
import pig/hooks.{type Hooks}
import pig/obs/consumer_spec.{type ConsumerSpec}
import pig/obs/dispatcher
import pig/obs/session
import pig/obs/terminal
import pig/skill
import pig/skill/librarian
import pig/tool

/// Opaque configuration builder. Construct with `new`, customize with
/// `with_*` functions, then `start` to spawn an agent actor.
pub opaque type PigConfig {
  PigConfig(
    agent_config: state.AgentConfig,
    skills: List(skill.Skill),
    consumer_specs: List(ConsumerSpec),
    hooks: List(Hooks),
    initial_history: List(Message),
  )
}

/// Opaque handle to a running agent actor.
pub opaque type Agent {
  Agent(subject: Subject(runtime.RuntimeMsg))
}

/// Create a new PigConfig with a provider and sensible defaults.
///
/// Defaults: empty tool registry, no system prompt, no skills,
/// no persistence, model "unknown", max iterations 50, no consumers.
pub fn new(provider: Provider) -> PigConfig {
  PigConfig(
    agent_config: state.config(provider),
    skills: [],
    consumer_specs: [],
    hooks: [],
    initial_history: [],
  )
}

/// Register a tool in the config.
pub fn with_tool(config: PigConfig, t: tool.Tool) -> PigConfig {
  let updated_registry = tool.register(config.agent_config.tools, t)
  PigConfig(
    ..config,
    agent_config: state.AgentConfig(
      ..config.agent_config,
      tools: updated_registry,
    ),
  )
}

/// Register multiple tools in the config.
pub fn with_tools(config: PigConfig, tools: List(tool.Tool)) -> PigConfig {
  list.fold(tools, config, with_tool)
}

/// Add a skill and register the librarian tool.
///
/// Skills are accumulated. On `start`, a single librarian tool is
/// created from all skills, and skill descriptions are injected
/// into the system prompt.
pub fn with_skill(config: PigConfig, s: skill.Skill) -> PigConfig {
  PigConfig(..config, skills: [s, ..config.skills])
}

/// Register a hooks set for lifecycle mediation.
pub fn with_hooks(config: PigConfig, h: Hooks) -> PigConfig {
  PigConfig(..config, hooks: list.append(config.hooks, [h]))
}

/// Set the system prompt.
pub fn with_system_prompt(config: PigConfig, prompt: String) -> PigConfig {
  PigConfig(
    ..config,
    agent_config: state.with_system_prompt(config.agent_config, prompt),
  )
}

/// Set the model name for telemetry and logging.
pub fn with_model(config: PigConfig, model: String) -> PigConfig {
  PigConfig(
    ..config,
    agent_config: state.with_model(config.agent_config, model),
  )
}

/// Set the agent name.
pub fn with_agent_name(config: PigConfig, name: String) -> PigConfig {
  PigConfig(
    ..config,
    agent_config: state.with_agent_name(config.agent_config, name),
  )
}

/// Set the agent ID.
pub fn with_agent_id(config: PigConfig, id: String) -> PigConfig {
  PigConfig(
    ..config,
    agent_config: state.with_agent_id(config.agent_config, id),
  )
}

/// Set the agent description.
pub fn with_agent_description(
  config: PigConfig,
  description: String,
) -> PigConfig {
  PigConfig(
    ..config,
    agent_config: state.with_agent_description(config.agent_config, description),
  )
}

/// Set the agent version.
pub fn with_agent_version(config: PigConfig, version: String) -> PigConfig {
  PigConfig(
    ..config,
    agent_config: state.with_agent_version(config.agent_config, version),
  )
}

/// Set the provider name.
pub fn with_provider_name(config: PigConfig, name: String) -> PigConfig {
  PigConfig(
    ..config,
    agent_config: state.with_provider_name(config.agent_config, name),
  )
}

/// Register a session writer consumer that writes JSONL to the given path.
/// Also sets session_path on agent config for replay on init.
pub fn with_session_writer(config: PigConfig, path: String) -> PigConfig {
  let name = process.new_name("pig_session_writer")
  let spec = session.supervised(path, name)
  let start_fn = fn() { session.start_consumer(path) }
  PigConfig(
    ..config,
    agent_config: state.with_session_path(config.agent_config, path),
    consumer_specs: [
      consumer_spec.ConsumerSpec(spec:, name:, start_fn:),
      ..config.consumer_specs
    ],
  )
}

/// Register a terminal output consumer that prints formatted events to stdout.
pub fn with_terminal_output(config: PigConfig) -> PigConfig {
  let name = process.new_name("pig_terminal")
  let spec = terminal.supervised(name)
  let start_fn = fn() { terminal.start_consumer() }
  PigConfig(..config, consumer_specs: [
    consumer_spec.ConsumerSpec(spec:, name:, start_fn:),
    ..config.consumer_specs
  ])
}

/// Register a custom consumer specification.
///
/// Appends to the list of consumer specs. Consumers receive pig's
/// `SessionEvent` stream — useful for bridging events into an external
/// store (e.g. a host runtime's observability table keyed by `run_id`).
///
/// This is the seam host runtimes use to capture pig's agent-internal
/// events (token usage, tool calls, inference timing) without pig ever
/// depending on them.
pub fn add_consumer(config: PigConfig, spec: ConsumerSpec) -> PigConfig {
  PigConfig(
    ..config,
    consumer_specs: list.append(config.consumer_specs, [spec]),
  )
}

/// Replace the list of consumer specifications.
///
/// Overwrites any previously registered consumers (including those added
/// by `with_session_writer` / `with_terminal_output` / `add_consumer`).
/// Pass an empty list to clear all consumers.
pub fn with_consumer_specs(
  config: PigConfig,
  specs: List(ConsumerSpec),
) -> PigConfig {
  PigConfig(..config, consumer_specs: specs)
}

/// Seed the conversation with initial messages.
///
/// Messages are appended to the agent's history after session replay
/// (if any) when the agent starts via `start()`. This allows resuming
/// a previous conversation or providing context before the first prompt.
///
/// The provider will see these messages on the first `run()` call,
/// along with any messages accumulated from session replay and the
/// new user prompt.
pub fn with_initial_history(
  config: PigConfig,
  messages: List(Message),
) -> PigConfig {
  PigConfig(..config, initial_history: messages)
}

/// Get the underlying AgentConfig. Useful for testing and inspection.
pub fn agent_config(config: PigConfig) -> state.AgentConfig {
  config.agent_config
}

/// Start an agent actor from the config.
///
/// Builds the final `AgentConfig`: registers the librarian tool if
/// skills are present, composes system prompt from skill descriptions.
/// Also creates a dispatcher actor and registers all configured consumers.
/// Returns an `Agent` handle for sending prompts.
pub fn start(config: PigConfig) -> Result(Agent, StartError) {
  let final_config = build_agent_config(config)

  // Start dispatcher
  case dispatcher.start() {
    Ok(dispatcher_subject) -> {
      // Try to start all consumers
      let consumer_results =
        list.map(config.consumer_specs, fn(entry) { entry.start_fn() })

      // Check if any consumer failed to start
      let failed =
        list.find(consumer_results, fn(r) {
          case r {
            Error(_) -> True
            Ok(_) -> False
          }
        })

      case failed {
        Ok(Error(e)) -> {
          // A consumer failed — shut down dispatcher
          process.send(dispatcher_subject, dispatcher.Stop)
          Error(e)
        }
        _ -> {
          // All consumers started OK — register them
          let consumer_subjects = list.filter_map(consumer_results, fn(r) { r })
          list.each(consumer_subjects, fn(consumer_subject) {
            process.send(
              dispatcher_subject,
              dispatcher.RegisterConsumer(consumer_subject),
            )
          })

          let runtime_config =
            runtime.RuntimeConfig(
              provider: final_config.provider,
              tools: final_config.tools,
              hooks: config.hooks,
              dispatcher: dispatcher_subject,
              model: final_config.model,
              max_iterations: final_config.max_iterations,
            )
          // Create initial state with system prompt and session replay.
          // System messages are stripped from both replay and initial history
          // because `messages_for_provider()` always prepends the configured
          // system prompt. Keeping them would cause duplication.
          let agent_st = case final_config.session_path {
            option.Some(path) -> {
              let st = state.new(final_config)
              case session.replay(path) {
                Ok(replayed) ->
                  list.fold(
                    strip_system_messages(replayed),
                    st,
                    state.add_message,
                  )
                Error(err) -> {
                  logging.log(
                    logging.Warning,
                    "Session replay failed for "
                      <> path
                      <> ": "
                      <> string.inspect(err),
                  )
                  st
                }
              }
            }
            option.None -> state.new(final_config)
          }
          // Apply initial history on top of session replay
          let agent_st =
            list.fold(
              strip_system_messages(config.initial_history),
              agent_st,
              state.add_message,
            )
          let rt_state =
            runtime.RuntimeState(agent_state: agent_st, config: runtime_config)
          case runtime.start_with_state(runtime_config, rt_state) {
            Ok(subject) -> Ok(Agent(subject))
            Error(e) -> {
              // Runtime failed — shut down consumers and dispatcher
              process.send(dispatcher_subject, dispatcher.Stop)
              Error(e)
            }
          }
        }
      }
    }
    Error(e) -> Error(e)
  }
}

/// Run a prompt against the agent with a 120-second default timeout.
pub fn run(agent: Agent, prompt: String) -> Result(Message, AiError) {
  run_with_timeout(agent, prompt, 120_000)
}

/// Run a prompt against the agent with an explicit timeout in milliseconds.
pub fn run_with_timeout(
  agent: Agent,
  prompt: String,
  timeout_ms: Int,
) -> Result(Message, AiError) {
  runtime.run(agent.subject, prompt, timeout_ms)
}

/// Run a prompt against the agent with an explicit timeout in milliseconds.
///
/// Returns `Error(Nil)` if the call times out or the agent crashes,
/// instead of panicking. Use this when you need resilience over panic-on-timeout.
pub fn try_run_with_timeout(
  agent: Agent,
  prompt: String,
  timeout_ms: Int,
) -> Result(Result(Message, AiError), Nil) {
  runtime.try_run(agent.subject, prompt, timeout_ms)
}

/// Resume the agent loop from its current history.
///
/// Used for the durability pattern: an external system checkpoints messages,
/// and on retry, rebuilds the agent's history from those checkpoints via
/// `with_initial_history`. This function continues the loop from where
/// the history left off, without adding a new user prompt.
///
/// Returns the final assistant message when the loop completes, or an error.
pub fn run_continue_with_timeout(
  agent: Agent,
  timeout_ms: Int,
) -> Result(Message, AiError) {
  runtime.run_continue(agent.subject, timeout_ms)
}

/// Resume the agent loop with a 120-second default timeout.
pub fn run_continue(agent: Agent) -> Result(Message, AiError) {
  run_continue_with_timeout(agent, 120_000)
}

/// Stop the agent actor.
pub fn stop(agent: Agent) -> Nil {
  runtime.stop(agent.subject)
}

/// Get the agent's current conversation history (all messages).
pub fn history(agent: Agent) -> List(message.Message) {
  runtime.history(agent.subject, 5000)
}

/// Return a PigConfig with a deterministic mock provider.
///
/// The mock provider always returns
/// `Assistant("mock response", [], None, None)`.
/// Useful for testing code that uses pig without hitting a real API.
pub fn test_harness() -> PigConfig {
  let response =
    message.Assistant("mock response", [], option.None, option.None)
  new(fn(_msgs, _tools) { Ok(from_message(response)) })
}

/// Strip System messages from a list.
///
/// System messages are managed exclusively by `AgentConfig.system_prompt`
/// and prepended by `messages_for_provider()`. Including them in history
/// (from session replay or initial_history) would cause duplication.
fn strip_system_messages(messages: List(Message)) -> List(Message) {
  list.filter(messages, fn(msg) {
    case msg {
      message.System(_) -> False
      _ -> True
    }
  })
}

/// Build the final AgentConfig from a PigConfig.
///
/// Registers librarian tool if skills are present and composes
/// system prompt from skill descriptions and tool info. Used by
/// `start` and `pig/supervisor.start_supervised`.
pub fn build_agent_config(config: PigConfig) -> state.AgentConfig {
  // Register librarian tool if skills present
  let config_with_librarian = case config.skills {
    [] -> config.agent_config
    skills -> {
      let librarian_tool = librarian.librarian_tool(skills)
      state.AgentConfig(
        ..config.agent_config,
        tools: tool.register(config.agent_config.tools, librarian_tool),
      )
    }
  }

  // Collect fragments to append to the system prompt
  let fragments = []

  // Compose skill descriptions
  let fragments = case config.skills {
    [] -> fragments
    skills -> {
      let skill_fragment =
        skills
        |> list.map(skill.skill_to_system_fragment)
        |> string.join("\n")
      [skill_fragment, ..fragments]
    }
  }

  // Compose tool info from registry (includes librarian if added)
  let tool_prompts = tool.list_tool_prompts(config_with_librarian.tools)
  let fragments = case tool_prompts {
    [] -> fragments
    prompts -> {
      let tool_lines =
        prompts
        |> list.map(fn(tp: tool.ToolPrompt) -> String {
          "- " <> tp.name <> ": " <> tp.description
        })
        |> string.join("\n")
      let tool_fragment = "Available tools:\n" <> tool_lines
      [tool_fragment, ..fragments]
    }
  }

  // Combine all fragments with the existing system prompt
  case fragments {
    [] -> config_with_librarian
    _ -> {
      let combined = case config_with_librarian.system_prompt {
        option.Some(existing) ->
          existing <> "\n\n" <> string.join(list.reverse(fragments), "\n\n")
        option.None -> string.join(list.reverse(fragments), "\n\n")
      }
      state.with_system_prompt(config_with_librarian, combined)
    }
  }
}
