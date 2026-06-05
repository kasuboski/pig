//// Top-level pig API tests.
////
//// Tests the builder pattern (new/with_*) and the run lifecycle
//// (start/run/stop). Per TESTING_STRATEGY §Axiom 1: test features,
//// not implementation.

import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import pig
import pig/agent/state
import pig/ai/message
import pig/skill
import support/harness

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Builder: new ─────────────────────────────────────────────────

/// new(provider) returns a config that can start and run.
pub fn new_starts_and_runs_test() {
  let response = message.Assistant("hello!", [], None, None)
  let config = pig.new(harness.fixed_provider(response))
  let assert Ok(agent) = pig.start(config)
  let assert Ok(msg) = pig.run_with_timeout(agent, "hi", 5000)
  let assert True = msg == response
  pig.stop(agent)
}

// ── Builder: with_tool ───────────────────────────────────────────

/// with_tool registers a tool the agent can call.
pub fn with_tool_registers_tool_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"hello\"}",
    )
  let tool_resp = message.Assistant("", [tc], None, None)
  let final = message.Assistant("done!", [], None, None)
  let provider = harness.sequenced_provider_for_actor([tool_resp, final])
  let config =
    pig.new(provider)
    |> pig.with_tool(harness.echo_tool())
  let assert Ok(agent) = pig.start(config)
  let assert Ok(msg) = pig.run_with_timeout(agent, "use echo", 5000)
  let assert True = msg == final
  pig.stop(agent)
}

// ── Builder: with_system_prompt ──────────────────────────────────

/// with_system_prompt sets the system prompt without breaking flow.
pub fn with_system_prompt_works_test() {
  let response = message.Assistant("ok", [], None, None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> pig.with_system_prompt("you are a test assistant")
  let assert Ok(agent) = pig.start(config)
  let assert Ok(msg) = pig.run_with_timeout(agent, "hi", 5000)
  let assert True = msg == response
  pig.stop(agent)
}

// ── Builder: with_model ──────────────────────────────────────────

/// with_model sets the model name without breaking flow.
pub fn with_model_works_test() {
  let response = message.Assistant("ok", [], None, None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> pig.with_model("test-model")
  let assert Ok(agent) = pig.start(config)
  let assert Ok(msg) = pig.run_with_timeout(agent, "hi", 5000)
  let assert True = msg == response
  pig.stop(agent)
}

// ── Builder: with_skill ──────────────────────────────────────────

/// with_skill adds a skill and registers the librarian tool.
pub fn with_skill_works_test() {
  let response = message.Assistant("ok", [], None, None)
  let s =
    skill.Skill(
      name: "test_skill",
      description: "A test skill",
      path: "test_data/skills/gleam-expert",
      files: [],
    )
  let config =
    pig.new(harness.fixed_provider(response))
    |> pig.with_skill(s)
  let assert Ok(agent) = pig.start(config)
  let assert Ok(msg) = pig.run_with_timeout(agent, "hi", 5000)
  let assert True = msg == response
  pig.stop(agent)
}

// ── Full builder flow ────────────────────────────────────────────

/// Full flow: new → with_tool → with_system_prompt → start → run.
pub fn full_builder_flow_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"test\"}",
    )
  let tool_resp = message.Assistant("", [tc], None, None)
  let final = message.Assistant("final answer", [], None, None)
  let config =
    pig.new(harness.sequenced_provider_for_actor([tool_resp, final]))
    |> pig.with_tool(harness.echo_tool())
    |> pig.with_system_prompt("test system prompt")
    |> pig.with_model("test-model")
  let assert Ok(agent) = pig.start(config)
  let assert Ok(msg) = pig.run_with_timeout(agent, "use echo tool", 5000)
  let assert True = msg == final
  pig.stop(agent)
}

// ── run_with_timeout ─────────────────────────────────────────────

/// run_with_timeout works with an explicit timeout.
pub fn run_with_timeout_works_test() {
  let response = message.Assistant("timed!", [], None, None)
  let config = pig.new(harness.fixed_provider(response))
  let assert Ok(agent) = pig.start(config)
  let assert Ok(msg) = pig.run_with_timeout(agent, "hi", 5000)
  let assert True = msg == response
  pig.stop(agent)
}

// ── test_harness ─────────────────────────────────────────────────

/// test_harness() returns a usable config with a mock provider.
pub fn test_harness_returns_config_test() {
  let config = pig.test_harness()
  let assert Ok(agent) = pig.start(config)
  let assert Ok(msg) = pig.run_with_timeout(agent, "hi", 5000)
  let assert True = msg == message.Assistant("mock response", [], None, None)
  pig.stop(agent)
}

// ── Builder: Agent Identity ────────────────────────────────────────

/// Helper to check that a builder method sets an identity field correctly
/// and the agent still runs end-to-end.
///
/// This follows TESTING_STRATEGY §Axiom 3 (check idiom): collapse
/// repeated patterns into a data-driven helper.
fn check_identity_builder(
  set_field: fn(pig.PigConfig, String) -> pig.PigConfig,
  get_field: fn(state.AgentConfig) -> Option(String),
  value: String,
) {
  let config = pig.test_harness() |> set_field(value)
  let agent_config = pig.agent_config(config)
  let result = get_field(agent_config)
  assert result == Some(value)
  let assert Ok(agent) = pig.start(config)
  let assert Ok(msg) = pig.run_with_timeout(agent, "hi", 5000)
  let assert True = msg == message.Assistant("mock response", [], None, None)
  pig.stop(agent)
}

/// with_agent_name sets the agent_name in the underlying AgentConfig.
pub fn with_agent_name_builder_test() {
  check_identity_builder(
    pig.with_agent_name,
    fn(c) { c.agent_name },
    "Math Tutor",
  )
}

/// with_provider_name sets the provider_name in the underlying AgentConfig.
pub fn with_provider_name_builder_test() {
  check_identity_builder(
    pig.with_provider_name,
    fn(c) { c.provider_name },
    "openai",
  )
}

/// with_agent_id sets the agent_id in the underlying AgentConfig.
pub fn with_agent_id_builder_test() {
  check_identity_builder(pig.with_agent_id, fn(c) { c.agent_id }, "agent-123")
}

/// with_agent_description sets the agent_description in the underlying AgentConfig.
pub fn with_agent_description_builder_test() {
  check_identity_builder(
    pig.with_agent_description,
    fn(c) { c.agent_description },
    "A helpful math tutor",
  )
}

/// with_agent_version sets the agent_version in the underlying AgentConfig.
pub fn with_agent_version_builder_test() {
  check_identity_builder(
    pig.with_agent_version,
    fn(c) { c.agent_version },
    "1.0.0",
  )
}

// ── System prompt auto-composition ────────────────────────────────

/// Centralized check for system prompt composition.
/// Builds the agent config from a PigConfig and asserts on the resulting
/// system prompt. If the API boundary changes, update HERE.
fn check_system_prompt(
  config: pig.PigConfig,
  assert_fn: fn(String) -> Nil,
) -> Nil {
  let cfg = pig.build_agent_config(config)
  let assert Some(prompt) = cfg.system_prompt
  assert_fn(prompt)
}

/// Tools with no system prompt: build_agent_config creates one from tools.
pub fn tools_auto_compose_system_prompt_test() {
  check_system_prompt(
    pig.test_harness() |> pig.with_tool(harness.echo_tool()),
    fn(prompt) {
      assert string.contains(prompt, "Available tools:")
      assert string.contains(prompt, "echo: Echoes back")
    },
  )
}

/// Tools append to existing system prompt.
pub fn tools_append_to_existing_system_prompt_test() {
  check_system_prompt(
    pig.test_harness()
      |> pig.with_system_prompt("You are helpful.")
      |> pig.with_tool(harness.echo_tool()),
    fn(prompt) {
      assert string.contains(prompt, "You are helpful.")
      assert string.contains(prompt, "Available tools:")
      assert string.contains(prompt, "echo: Echoes back")
    },
  )
}

/// No tools and no system prompt: system_prompt stays None.
pub fn no_tools_no_prompt_means_no_system_prompt_test() {
  let config = pig.test_harness()
  let cfg = pig.build_agent_config(config)
  assert cfg.system_prompt == None
}