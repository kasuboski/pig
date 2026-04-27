//// Top-level pig API tests.
////
//// Tests the builder pattern (new/with_*) and the run lifecycle
//// (start/run/stop). Per TESTING_STRATEGY §Axiom 1: test features,
//// not implementation.

import gleam/option.{None}
import gleeunit
import pig
import pig/ai/message
import pig/skill
import support/harness

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Builder: new ─────────────────────────────────────────────────

/// new(provider) returns a config that can start and run.
pub fn new_starts_and_runs_test() {
  let response = message.Assistant("hello!", [], None)
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
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("done!", [], None)
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
  let response = message.Assistant("ok", [], None)
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
  let response = message.Assistant("ok", [], None)
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
  let response = message.Assistant("ok", [], None)
  let s = skill.Skill(
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

// ── Builder: with_persistence ────────────────────────────────────

/// with_persistence sets the session path without breaking flow.
/// Actual persistence tested in Phase 9.
pub fn with_persistence_works_test() {
  let response = message.Assistant("ok", [], None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> pig.with_persistence("/tmp/pig_test_sessions")
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
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("final answer", [], None)
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
  let response = message.Assistant("timed!", [], None)
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
  let assert True = msg == message.Assistant("mock response", [], None)
  pig.stop(agent)
}
