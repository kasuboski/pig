//// Agent state contract tests.
////
//// Tests behavioral contracts of AgentConfig/AgentState, NOT
//// getter/setter round-trips. Per TESTING_STRATEGY §Axiom 1:
//// "If we entirely replace the internals, no tests should break."

import gleam/list
import gleam/option.{None, Some}
import gleeunit
import pig/agent/state
import pig/ai/message
import pig/ai/provider
import support/harness

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Immutability Contract ────────────────────────────────────────

pub fn add_message_does_not_mutate_original_test() {
  let s = harness.state_for_step([], []) |> state.add_message(message.User("a"))
  let s1 = state.add_message(s, message.User("first"))
  let _s2 = state.add_message(s, message.User("second"))
  // s1 is independent — original s has "a", s1 has "a"+"first"
  state.history(s1) == [message.User("a"), message.User("first")]
}

pub fn add_message_preserves_insertion_order_test() {
  let s =
    harness.state_for_step([], [])
    |> state.add_message(message.System("sys"))
    |> state.add_message(message.User("hello"))
    |> state.add_message(message.Assistant("hi", [], None))
  let assert [
    message.System("sys"),
    message.User("hello"),
    message.Assistant("hi", [], None),
  ] = state.history(s)
  True
}

// ── System Prompt Contract ───────────────────────────────────────

/// System prompt is NOT included in raw history.
pub fn system_prompt_not_in_history_test() {
  let s =
    harness.state_with_system_prompt([], [], "you are helpful")
    |> state.add_message(message.User("hello"))
  // history has only the user message
  state.history(s) == [message.User("hello")]
}

/// messages_for_provider prepends system prompt before history.
pub fn messages_for_provider_injects_system_prompt_test() {
  let s =
    harness.state_with_system_prompt([], [], "you are helpful")
    |> state.add_message(message.User("hello"))
  state.messages_for_provider(s)
  == [
    message.System("you are helpful"),
    message.User("hello"),
  ]
}

/// Without system prompt, messages_for_provider returns raw history.
pub fn messages_for_provider_returns_history_when_no_prompt_test() {
  let s =
    harness.state_for_step([], [])
    |> state.add_message(message.User("hello"))
  state.messages_for_provider(s) == [message.User("hello")]
}

// ── Tool Registry Contract ───────────────────────────────────────

/// Tool definitions are extracted from the registry for provider calls.
pub fn tool_definitions_available_from_state_test() {
  let s = harness.state_for_step([], [harness.echo_tool()])
  let defs = state.tool_definitions(s)
  list.length(defs) == 1
}

// ── Max Iterations Contract ──────────────────────────────────────

/// exceeded_max_iterations starts false, becomes true after incrementing.
pub fn exceeded_max_iterations_boundary_test() {
  let s = harness.state_with_max_iterations([], [], 2)
  // Not exceeded initially
  !state.exceeded_max_iterations(s)
  && {
    let s1 = state.increment_iterations(s)
    !state.exceeded_max_iterations(s1)
    && {
      let s2 = state.increment_iterations(s1)
      state.exceeded_max_iterations(s2)
    }
  }
}

// ── Agent Identity Contract ───────────────────────────────────────

/// Agent identity fields (agent_id, agent_name, agent_description,
/// agent_version, provider_name) all default to None.
pub fn agent_identity_defaults_to_none_test() {
  let msg = message.Assistant("hi", [], None)
  let config = state.config(fn(_msgs, _tools) {
    Ok(provider.from_message(msg))
  })
  let assert None = config.agent_id
  let assert None = config.agent_name
  let assert None = config.agent_description
  let assert None = config.agent_version
  let assert None = config.provider_name
  True
}

/// with_agent_name sets the agent_name field.
pub fn with_agent_name_sets_name_test() {
  let msg = message.Assistant("hi", [], None)
  let config = state.config(fn(_msgs, _tools) {
    Ok(provider.from_message(msg))
  })
  let config = state.with_agent_name(config, "Math Tutor")
  let assert Some("Math Tutor") = config.agent_name
  True
}

/// with_agent_id sets the agent_id field.
pub fn with_agent_id_sets_id_test() {
  let msg = message.Assistant("hi", [], None)
  let config = state.config(fn(_msgs, _tools) {
    Ok(provider.from_message(msg))
  })
  let config = state.with_agent_id(config, "agent-123")
  let assert Some("agent-123") = config.agent_id
  True
}

/// with_provider_name sets the provider_name field.
pub fn with_provider_name_sets_provider_name_test() {
  let msg = message.Assistant("hi", [], None)
  let config = state.config(fn(_msgs, _tools) {
    Ok(provider.from_message(msg))
  })
  let config = state.with_provider_name(config, "openai")
  let assert Some("openai") = config.provider_name
  True
}
