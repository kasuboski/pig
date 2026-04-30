import gleeunit
import gleeunit/should
import gleam/erlang/process
import gleam/list
import gleam/string
import gleam/option
import pig
import pig/ai/message
import pig/hooks
import simplifile
import temporary

pub fn main() {
  gleeunit.main()
}

// ── Test Helpers ──────────────────────────────────────────────────────

/// Run a test with a temporary JSONL file. Auto-cleaned after callback returns.
fn with_temp_file(
  name: String,
  run test_fn: fn(String) -> a,
) -> a {
  let tmp =
    temporary.file()
    |> temporary.with_prefix("pig_config_" <> name <> "_")
    |> temporary.with_suffix(".jsonl")
  let assert Ok(result) = temporary.create(tmp, test_fn)
  result
}

fn read_file(path: String) -> Result(String, simplifile.FileError) {
  simplifile.read(path)
}

// ── Builder Tests (Pure, No Actors) ────────────────────────────────────

// Test 1: Default PigConfig has empty consumer_specs
pub fn default_config_has_empty_consumer_specs_test() {
  let config = pig.test_harness()

  // Default config should work without any consumers (backward compat)
  let assert Ok(agent) = pig.start(config)
  pig.stop(agent)
}

// Test 2: with_session_writer adds a consumer spec
pub fn with_session_writer_adds_consumer_spec_test() {
  use path <- with_temp_file("writer_spec")
  let config = pig.test_harness()

  // Add a session writer
  let config_with_writer =
    config |> pig.with_session_writer(path)

  // Config should be usable to start an agent
  let assert Ok(agent) = pig.start(config_with_writer)
  pig.stop(agent)
}

// Test 3: with_terminal_output adds a consumer spec
pub fn with_terminal_output_adds_consumer_spec_test() {
  let config = pig.test_harness()

  // Add a terminal output consumer
  let config_with_terminal = config |> pig.with_terminal_output()

  // Config should be usable to start an agent
  let assert Ok(agent) = pig.start(config_with_terminal)
  pig.stop(agent)
}

// Test 4: with_session_writer + with_terminal_output accumulates both
pub fn multiple_consumers_accumulate_test() {
  use path <- with_temp_file("both_consumers")
  let config = pig.test_harness()

  // Add both consumers
  let config_with_both =
    config
    |> pig.with_session_writer(path)
    |> pig.with_terminal_output()

  // Config should be usable to start an agent
  let assert Ok(agent) = pig.start(config_with_both)
  pig.stop(agent)
}

// ── Integration Tests (With Actors) ─────────────────────────────────────

// Helper to extract content from a Message
fn get_content(msg: message.Message) -> String {
  case msg {
    message.User(content) -> content
    message.System(content) -> content
    message.Assistant(content, _, _) -> content
    message.Tool(_, content) -> content
  }
}

// Test 5: start() with no consumers still works (backward compatibility)
pub fn start_without_consumers_works_test() {
  let config = pig.test_harness()

  // Start should work with no consumers
  let assert Ok(agent) = pig.start(config)

  // Run a prompt to verify the agent works
  let assert Ok(response) = pig.run(agent, "test")
  get_content(response) |> should.equal("mock response")

  pig.stop(agent)
}

// Test 6: start() with no dispatcher configured works correctly
pub fn start_without_dispatcher_configured_works_test() {
  let config = pig.test_harness()

  // Get the agent config to verify dispatcher is None initially (before start)
  let agent_cfg = pig.agent_config(config)

  // The dispatcher should be None initially (before start)
  agent_cfg.dispatcher |> should.equal(option.None)

  // Start the agent
  let assert Ok(agent) = pig.start(config)

  // After start, the agent should be functional
  let assert Ok(response) = pig.run(agent, "test")
  get_content(response) |> should.equal("mock response")

  pig.stop(agent)
}

// Test 7: start() with session_writer consumer creates consumer and registers it
pub fn start_with_session_writer_registers_consumer_test() {
  use tmp_file <- with_temp_file("session_writer_reg")
  let config =
    pig.test_harness()
    |> pig.with_session_writer(tmp_file)

  // Start the agent
  let assert Ok(agent) = pig.start(config)

  // Run a prompt to trigger events
  let assert Ok(response) = pig.run(agent, "test")
  get_content(response) |> should.equal("mock response")

  // Give the consumer time to write
  let _ = process.receive(process.new_subject(), 100)

  // Stop the agent
  pig.stop(agent)

  // Check that the session file was created and has content
  // Note: need simplifile to read the file
  let assert Ok(content) = read_file(tmp_file)

  let lines = string.split(content, "\n")
  let non_empty_lines = list.filter(lines, fn(l) { l != "" })

  // Should have at least one event line
  let line_count = list.length(non_empty_lines)
  line_count |> should.not_equal(0)
}

// ── Hooks Tests ──────────────────────────────────────────────────────

// Test 8: with_hooks adds hooks to agent config
pub fn with_hooks_adds_hooks_to_config_test() {
  let h = hooks.new("test-hook")
  let config =
    pig.test_harness()
    |> pig.with_hooks(h)

  let agent_cfg = pig.agent_config(config)
  list.length(agent_cfg.hooks) |> should.equal(1)
}

// Test 9: with_hooks can be chained
pub fn with_hooks_chains_multiple_test() {
  let h1 = hooks.new("first")
  let h2 = hooks.new("second")
  let config =
    pig.test_harness()
    |> pig.with_hooks(h1)
    |> pig.with_hooks(h2)

  let agent_cfg = pig.agent_config(config)
  list.length(agent_cfg.hooks) |> should.equal(2)
}

// Test 10: with_session_writer sets session_path on agent config
pub fn with_session_writer_sets_session_path_test() {
  let config =
    pig.test_harness()
    |> pig.with_session_writer("/tmp/test.jsonl")

  let agent_cfg = pig.agent_config(config)
  agent_cfg.session_path |> should.equal(option.Some("/tmp/test.jsonl"))
}

// Test 11: default config has no session_path
pub fn default_config_has_no_session_path_test() {
  let config = pig.test_harness()
  let agent_cfg = pig.agent_config(config)
  agent_cfg.session_path |> should.equal(option.None)
}
