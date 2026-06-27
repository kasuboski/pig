import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import pig
import pig/ai/message
import pig/ai/provider
import pig/hooks
import simplifile
import temporary

pub fn main() {
  gleeunit.main()
}

// ── Test Helpers ──────────────────────────────────────────────────────

/// Run a test with a temporary JSONL file. Auto-cleaned after callback returns.
fn with_temp_file(name: String, run test_fn: fn(String) -> a) -> a {
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
  let config_with_writer = config |> pig.with_session_writer(path)

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
    message.Assistant(content, _, _, _) -> content
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
  assert get_content(response) == "mock response"

  pig.stop(agent)
}

// Test 6: start() with no dispatcher configured works correctly
pub fn start_without_dispatcher_configured_works_test() {
  let config = pig.test_harness()

  // Start the agent
  let assert Ok(agent) = pig.start(config)

  // After start, the agent should be functional
  let assert Ok(response) = pig.run(agent, "test")
  assert get_content(response) == "mock response"

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
  assert get_content(response) == "mock response"

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
  assert line_count != 0
}

// ── Hooks Tests ──────────────────────────────────────────────────────

// Test 8: with_hooks adds hooks to PigConfig
pub fn with_hooks_adds_hooks_to_config_test() {
  let h = hooks.new("test-hook")
  let config =
    pig.test_harness()
    |> pig.with_hooks(h)

  // Verify by starting and running — hooks don't crash
  let assert Ok(agent) = pig.start(config)
  let assert Ok(response) = pig.run(agent, "test")
  assert get_content(response) == "mock response"
  pig.stop(agent)
}

// Test 9: with_hooks can be chained
pub fn with_hooks_chains_multiple_test() {
  let h1 = hooks.new("first")
  let h2 = hooks.new("second")
  let config =
    pig.test_harness()
    |> pig.with_hooks(h1)
    |> pig.with_hooks(h2)

  // Verify by starting and running — multiple hooks don't crash
  let assert Ok(agent) = pig.start(config)
  let assert Ok(response) = pig.run(agent, "test")
  assert get_content(response) == "mock response"
  pig.stop(agent)
}

// Test 10: with_session_writer sets session_path on agent config
pub fn with_session_writer_sets_session_path_test() {
  let config =
    pig.test_harness()
    |> pig.with_session_writer("/tmp/test.jsonl")

  let agent_cfg = pig.agent_config(config)
  assert agent_cfg.session_path == option.Some("/tmp/test.jsonl")
}

// Test 11: default config has no session_path
pub fn default_config_has_no_session_path_test() {
  let config = pig.test_harness()
  let agent_cfg = pig.agent_config(config)
  assert agent_cfg.session_path == option.None
}

// ── Initial History Tests ──────────────────────────────────────────

// Test 12: with_initial_history works with a single message
pub fn with_initial_history_single_message_test() {
  let config =
    pig.test_harness()
    |> pig.with_initial_history([message.User("hello from the past")])

  let assert Ok(agent) = pig.start(config)
  let assert Ok(response) = pig.run(agent, "test")
  assert get_content(response) == "mock response"
  pig.stop(agent)
}

// Test 13: with_initial_history with empty list is a no-op
pub fn with_initial_history_empty_list_is_noop_test() {
  let config =
    pig.test_harness()
    |> pig.with_initial_history([])

  let assert Ok(agent) = pig.start(config)
  let assert Ok(response) = pig.run(agent, "test")
  assert get_content(response) == "mock response"
  pig.stop(agent)
}

// Test 14: with_initial_history with multiple message types
pub fn with_initial_history_multiple_messages_test() {
  let config =
    pig.test_harness()
    |> pig.with_initial_history([
      message.User("what is 2+2?"),
      message.Assistant("4", [], option.None, option.None),
    ])

  let assert Ok(agent) = pig.start(config)
  let assert Ok(response) = pig.run(agent, "continue")
  assert get_content(response) == "mock response"
  pig.stop(agent)
}

// Test 15: with_initial_history chains with session_writer
pub fn with_initial_history_chains_with_session_writer_test() {
  use tmp_file <- with_temp_file("initial_history_session")
  let config =
    pig.test_harness()
    |> pig.with_session_writer(tmp_file)
    |> pig.with_initial_history([message.User("seed")])

  let assert Ok(agent) = pig.start(config)
  let assert Ok(response) = pig.run(agent, "test")
  assert get_content(response) == "mock response"
  pig.stop(agent)
}

// Test 16: provider sees initial history messages on first run
pub fn with_initial_history_provider_sees_messages_test() {
  let seen = process.new_subject()
  let mock_response =
    message.Assistant("mock response", [], option.None, option.None)
  let provider_fn = fn(msgs, _tools) {
    let user_contents =
      msgs
      |> list.filter(fn(m) {
        case m {
          message.User(_) -> True
          _ -> False
        }
      })
      |> list.map(fn(m) {
        let assert message.User(content) = m
        content
      })
    process.send(seen, user_contents)
    Ok(provider.from_message(mock_response))
  }
  let config =
    pig.new(provider_fn)
    |> pig.with_initial_history([
      message.User("previous question"),
      message.Assistant("previous answer", [], option.None, option.None),
    ])

  let assert Ok(agent) = pig.start(config)
  let assert Ok(_response) = pig.run(agent, "new question")
  pig.stop(agent)

  // Provider should see both the initial history user message and the new one
  let assert Ok(user_contents) = process.receive(seen, 2000)
  assert user_contents == ["previous question", "new question"]
}

// Test 17: System messages in initial_history are stripped
//
// System messages are managed exclusively by with_system_prompt() and
// prepended by messages_for_provider(). Including them in history would
// cause duplication.
pub fn with_initial_history_strips_system_messages_test() {
  let seen = process.new_subject()
  let mock_response =
    message.Assistant("mock response", [], option.None, option.None)
  let provider_fn = fn(msgs, _tools) {
    let system_msgs =
      msgs
      |> list.filter(fn(m) {
        case m {
          message.System(_) -> True
          _ -> False
        }
      })
      |> list.length()
    process.send(seen, system_msgs)
    Ok(provider.from_message(mock_response))
  }
  let config =
    pig.new(provider_fn)
    |> pig.with_system_prompt("configured prompt")
    |> pig.with_initial_history([
      message.System("should be stripped"),
      message.User("hello"),
      message.System("also stripped"),
    ])

  let assert Ok(agent) = pig.start(config)
  let assert Ok(_response) = pig.run(agent, "test")
  pig.stop(agent)

  // Provider should see exactly 1 System message — the one from with_system_prompt
  let assert Ok(system_count) = process.receive(seen, 2000)
  assert system_count == 1
}
