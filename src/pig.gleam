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
          // A consumer failed — return error
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
          // Create initial state with system prompt and session replay
          let agent_st = case final_config.session_path {
            option.Some(path) -> {
              let st = state.new(final_config)
              case session.replay(path) {
                Ok(replayed) -> list.fold(replayed, st, state.add_message)
                Error(_) -> st
              }
            }
            option.None -> state.new(final_config)
          }
          let rt_state =
            runtime.RuntimeState(agent_state: agent_st, config: runtime_config)
          case runtime.start_with_state(runtime_config, rt_state) {
            Ok(subject) -> Ok(Agent(subject))
            Error(e) -> Error(e)
          }
        }
      }
    }
    Error(e) -> Error(e)
  }
}

/// Run a prompt against the agent with a 30-second default timeout.
pub fn run(agent: Agent, prompt: String) -> Result(Message, AiError) {
  run_with_timeout(agent, prompt, 30_000)
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

/// Stop the agent actor.
pub fn stop(agent: Agent) -> Nil {
  runtime.stop(agent.subject)
}

/// Return a PigConfig with a deterministic mock provider.
///
/// The mock provider always returns
/// `Assistant("mock response", [], None)`.
/// Useful for testing code that uses pig without hitting a real API.
pub fn test_harness() -> PigConfig {
  let response = message.Assistant("mock response", [], option.None)
  new(fn(_msgs, _tools) { Ok(from_message(response)) })
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
