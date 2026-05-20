//// Agent state contract tests.
////
//// Tests behavioral contracts of AgentConfig/AgentState, NOT
//// getter/setter round-trips. Per TESTING_STRATEGY §Axiom 1:
//// "If we entirely replace the internals, no tests should break."

import gleam/list
import gleam/option.{None}
import gleeunit
import pig/agent/state
import pig/ai/message
import pig/ai/provider
import pig/tool
import support/harness

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Helpers ──────────────────────────────────────────────────────

fn dummy_provider() {
  fn(_msgs, _tools) {
    Ok(provider.from_message(message.Assistant("x", [], None)))
  }
}

fn new_state(tools: List(tool.Tool)) -> state.AgentState {
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  state.config(dummy_provider()) |> state.with_tools(registry) |> state.new()
}

fn new_state_with_prompt(
  tools: List(tool.Tool),
  prompt: String,
) -> state.AgentState {
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  state.config(dummy_provider())
  |> state.with_tools(registry)
  |> state.with_system_prompt(prompt)
  |> state.new()
}

fn new_state_with_max(tools: List(tool.Tool), max: Int) -> state.AgentState {
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  state.config(dummy_provider())
  |> state.with_tools(registry)
  |> state.with_max_iterations(max)
  |> state.new()
}

// ── Immutability Contract ────────────────────────────────────────

pub fn add_message_does_not_mutate_original_test() {
  let s = new_state([]) |> state.add_message(message.User("a"))
  let s1 = state.add_message(s, message.User("first"))
  let _s2 = state.add_message(s, message.User("second"))
  // s1 is independent — original s has "a", s1 has "a"+"first"
  assert state.history(s1) == [message.User("a"), message.User("first")]
}

pub fn add_message_preserves_insertion_order_test() {
  let s =
    new_state([])
    |> state.add_message(message.System("sys"))
    |> state.add_message(message.User("hello"))
    |> state.add_message(message.Assistant("hi", [], None))
  let assert [
    message.System("sys"),
    message.User("hello"),
    message.Assistant("hi", [], None),
  ] = state.history(s)
  Nil
}

// ── System Prompt Contract ───────────────────────────────────────

/// System prompt is NOT included in raw history.
pub fn system_prompt_not_in_history_test() {
  let s =
    new_state_with_prompt([], "you are helpful")
    |> state.add_message(message.User("hello"))
  // history has only the user message
  assert state.history(s) == [message.User("hello")]
}

/// messages_for_provider prepends system prompt before history.
pub fn messages_for_provider_injects_system_prompt_test() {
  let s =
    new_state_with_prompt([], "you are helpful")
    |> state.add_message(message.User("hello"))
  assert state.messages_for_provider(s)
    == [
      message.System("you are helpful"),
      message.User("hello"),
    ]
}

/// Without system prompt, messages_for_provider returns raw history.
pub fn messages_for_provider_returns_history_when_no_prompt_test() {
  let s =
    new_state([])
    |> state.add_message(message.User("hello"))
  assert state.messages_for_provider(s) == [message.User("hello")]
}

// ── Tool Registry Contract ───────────────────────────────────────

/// Tool definitions are extracted from the registry for provider calls.
pub fn tool_definitions_available_from_state_test() {
  let s = new_state([harness.echo_tool()])
  let defs = state.tool_definitions(s)
  assert list.length(defs) == 1
}

// ── Max Iterations Contract ──────────────────────────────────────

/// exceeded_max_iterations starts false, becomes true after incrementing.
pub fn exceeded_max_iterations_boundary_test() {
  let s = new_state_with_max([], 2)
  // Not exceeded initially
  assert !state.exceeded_max_iterations(s)
  let s1 = state.increment_iterations(s)
  assert !state.exceeded_max_iterations(s1)
  let s2 = state.increment_iterations(s1)
  assert state.exceeded_max_iterations(s2)
}

// ── Session Path Config ────────────────────────────────────────────

/// Default config has no session path.
pub fn default_config_has_no_session_path_test() {
  let cfg = state.config(dummy_provider())
  assert cfg.session_path == None
}

/// with_session_path sets the field.
pub fn with_session_path_sets_path_test() {
  let cfg = state.config(dummy_provider())
  let cfg2 = state.with_session_path(cfg, "/tmp/test.jsonl")
  assert cfg2.session_path == option.Some("/tmp/test.jsonl")
}

/// with_session_path does not mutate original.
pub fn with_session_path_does_not_mutate_original_test() {
  let cfg = state.config(dummy_provider())
  let _cfg2 = state.with_session_path(cfg, "/tmp/test.jsonl")
  assert cfg.session_path == None
}
