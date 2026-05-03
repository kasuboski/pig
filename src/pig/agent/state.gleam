//// Agent state types and configuration.
////
//// `AgentConfig` holds the immutable configuration for creating an agent.
//// `AgentState` holds the runtime state (history, iterations).
//// State is immutable — every mutation returns a new state.

import gleam/erlang/process.{type Name, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import pig/ai/error.{type AiError}
import pig/ai/message.{type Message}
import pig/ai/provider.{type Provider}
import pig/ai/tool_definition.{type ToolDefinition}
import pig/hooks.{type Hooks}
import pig/tool.{type ToolRegistry}
import pig/obs/dispatcher

/// Configuration for creating an agent. Immutable once constructed.
pub type AgentConfig {
  AgentConfig(
    provider: Provider,
    tools: ToolRegistry,
    system_prompt: Option(String),
    max_iterations: Int,
    model: String,
    // Agent identity fields
    agent_id: Option(String),
    agent_name: Option(String),
    agent_description: Option(String),
    agent_version: Option(String),
    provider_name: Option(String),
    // Hooks and session fields
    hooks: List(Hooks),
    session_path: Option(String),
    // Observability fields
    dispatcher_name: Option(Name(dispatcher.DispatcherMessage)),
    dispatcher: Option(Subject(dispatcher.DispatcherMessage)),
  )
}

/// Runtime state of an agent. Immutable — mutations return new state.
pub type AgentState {
  AgentState(
    config: AgentConfig,
    history: List(Message),
    iterations: Int,
  )
}

/// Create an AgentConfig with defaults.
///
/// Default values:
/// - `tools`: empty registry
/// - `system_prompt`: None
/// - `max_iterations`: 50
/// - `model`: "unknown"
/// - `agent_id`: None
/// - `agent_name`: None
/// - `agent_description`: None
/// - `agent_version`: None
/// - `provider_name`: None
/// - `dispatcher_name`: None
/// - `dispatcher`: None
pub fn config(provider: Provider) -> AgentConfig {
  AgentConfig(
    provider:,
    tools: tool.new_registry(),
    system_prompt: option.None,
    max_iterations: 50,
    model: "unknown",
    agent_id: option.None,
    agent_name: option.None,
    agent_description: option.None,
    agent_version: option.None,
    provider_name: option.None,
    hooks: [],
    session_path: option.None,
    dispatcher_name: option.None,
    dispatcher: option.None,
  )
}

/// Set the tool registry on the config.
pub fn with_tools(config: AgentConfig, tools: ToolRegistry) -> AgentConfig {
  AgentConfig(..config, tools:)
}

/// Set the system prompt on the config.
pub fn with_system_prompt(
  config: AgentConfig,
  prompt: String,
) -> AgentConfig {
  AgentConfig(..config, system_prompt: option.Some(prompt))
}

/// Set the maximum number of loop iterations before forcing termination.
pub fn with_max_iterations(
  config: AgentConfig,
  max: Int,
) -> AgentConfig {
  AgentConfig(..config, max_iterations: max)
}

/// Set the model name for telemetry and logging.
pub fn with_model(config: AgentConfig, model: String) -> AgentConfig {
  AgentConfig(..config, model:)
}

/// Set the agent ID.
pub fn with_agent_id(config: AgentConfig, id: String) -> AgentConfig {
  AgentConfig(..config, agent_id: option.Some(id))
}

/// Set the agent name.
pub fn with_agent_name(config: AgentConfig, name: String) -> AgentConfig {
  AgentConfig(..config, agent_name: option.Some(name))
}

/// Set the agent description.
pub fn with_agent_description(
  config: AgentConfig,
  desc: String,
) -> AgentConfig {
  AgentConfig(..config, agent_description: option.Some(desc))
}

/// Set the agent version.
pub fn with_agent_version(config: AgentConfig, version: String) -> AgentConfig {
  AgentConfig(..config, agent_version: option.Some(version))
}

/// Set the provider name.
pub fn with_provider_name(config: AgentConfig, name: String) -> AgentConfig {
  AgentConfig(..config, provider_name: option.Some(name))
}

/// Set the dispatcher name for observability.
/// The agent will emit events to this dispatcher via events.emit_to().
pub fn with_dispatcher_name(
  config: AgentConfig,
  name: Name(dispatcher.DispatcherMessage),
) -> AgentConfig {
  AgentConfig(..config, dispatcher_name: option.Some(name))
}

/// Set the dispatcher subject for observability.
/// The agent will emit SessionEvents to this dispatcher via emit.to_dispatcher().
pub fn with_dispatcher(
  config: AgentConfig,
  subject: Subject(dispatcher.DispatcherMessage),
) -> AgentConfig {
  AgentConfig(..config, dispatcher: option.Some(subject))
}

/// Append a hooks set to the hooks list.
pub fn with_hooks(config: AgentConfig, h: Hooks) -> AgentConfig {
  AgentConfig(..config, hooks: list.append(config.hooks, [h]))
}

/// Set the session path for persistence and replay.
pub fn with_session_path(config: AgentConfig, path: String) -> AgentConfig {
  AgentConfig(..config, session_path: option.Some(path))
}

/// Create initial agent state from config.
pub fn new(config: AgentConfig) -> AgentState {
  AgentState(config:, history: [], iterations: 0)
}

/// Replace the provider on an existing state.
/// Useful for tests that need to inject a specific provider
/// after state construction.
pub fn config_put_provider(
  st: AgentState,
  provider: Provider,
) -> AgentState {
  AgentState(
    config: AgentConfig(..st.config, provider:),
    history: st.history,
    iterations: st.iterations,
  )
}

/// Add a message to the end of history. Returns new state.
pub fn add_message(state: AgentState, msg: Message) -> AgentState {
  AgentState(..state, history: list.append(state.history, [msg]))
}

/// Get the conversation history in order.
pub fn history(state: AgentState) -> List(Message) {
  state.history
}

/// Increment the iteration counter. Returns new state.
pub fn increment_iterations(state: AgentState) -> AgentState {
  AgentState(..state, iterations: state.iterations + 1)
}

/// Check if the agent has exceeded its maximum iterations.
pub fn exceeded_max_iterations(state: AgentState) -> Bool {
  state.iterations >= state.config.max_iterations
}

/// Get tool definitions from the registry.
pub fn tool_definitions(state: AgentState) -> List(ToolDefinition) {
  tool.list_definitions(state.config.tools)
}

/// Get messages for a provider call.
///
/// Prepends the system prompt as a `System` message if one is configured.
pub fn messages_for_provider(state: AgentState) -> List(Message) {
  case state.config.system_prompt {
    option.Some(prompt) ->
      [message.System(content: prompt), ..state.history]
    option.None -> state.history
  }
}

/// Build an `AiError` for exceeding max iterations.
pub fn max_iterations_error(state: AgentState) -> AiError {
  error.ApiError(
    "Agent exceeded maximum iterations ("
    <> int.to_string(state.config.max_iterations)
    <> ")",
  )
}
