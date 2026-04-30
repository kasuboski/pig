//// Agent state contract tests.
////
//// Tests behavioral contracts of AgentConfig/AgentState, NOT
//// getter/setter round-trips. Per TESTING_STRATEGY §Axiom 1:
//// "If we entirely replace the internals, no tests should break."

import gleeunit
import gleam/list
import gleam/option.{None}
import gleam/erlang/process
import gleeunit/should
import pig/agent/state
import pig/ai/message
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

// ── Dispatcher Config ──────────────────────────────────────────────

/// Default config has no dispatcher_name.
pub fn default_config_has_no_dispatcher_name_test() {
  let cfg = state.config(harness.fixed_provider(message.Assistant("OK", [], None)))
  cfg.dispatcher_name |> should.equal(option.None)
}

/// with_dispatcher_name sets the dispatcher_name field.
pub fn with_dispatcher_name_sets_name_test() {
  let cfg = state.config(harness.fixed_provider(message.Assistant("OK", [], None)))
  let name = process.new_name("test_dispatcher")
  let cfg2 = state.with_dispatcher_name(cfg, name)
  cfg2.dispatcher_name |> should.equal(option.Some(name))
}

/// with_dispatcher_name does not mutate original config.
pub fn with_dispatcher_name_does_not_mutate_original_test() {
  let cfg = state.config(harness.fixed_provider(message.Assistant("OK", [], None)))
  let name = process.new_name("test_dispatcher")
  let cfg2 = state.with_dispatcher_name(cfg, name)
  
  // Original config still has None
  cfg.dispatcher_name |> should.equal(option.None)
  // New config has the name
  cfg2.dispatcher_name |> should.equal(option.Some(name))
}


