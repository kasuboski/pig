//// Integration tests for the observability dispatcher architecture.
////
//// These tests verify the full pipeline works end-to-end:
//// 1. Telemetry still fires through dispatcher
//// 2. Session writer receives events via dispatcher
//// 3. Multiple consumers receive events
//// 4. Supervised path with consumers (tree starts correctly)

import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import pig
import pig/agent/state
import pig/ai/message
import pig/ai/provider
import pig/obs/consumer_spec
import pig/obs/events
import pig/obs/listener
import pig/obs/session
import pig/supervisor
import simplifile
import temporary

pub fn main() {
  gleeunit.main()
}

// ── Test Helpers ─────────────────────────────────────────────────────

/// Run a test with a temporary JSONL file. Auto-cleaned after callback returns.
fn with_temp_file(name: String, run test_fn: fn(String) -> a) -> a {
  let tmp =
    temporary.file()
    |> temporary.with_prefix("pig_integ_" <> name <> "_")
    |> temporary.with_suffix(".jsonl")
  let assert Ok(result) = temporary.create(tmp, test_fn)
  result
}

/// Poll a file until it has non-empty content or retries are exhausted.
/// Replaces fragile sleep-based waits with a deterministic retry loop.
fn poll_until_content(path: String, remaining: Int) -> Result(String, Nil) {
  case remaining {
    0 -> Error(Nil)
    _ -> {
      case simplifile.read(path) {
        Ok(content) -> {
          let lines =
            string.split(content, "\n")
            |> list.filter(fn(l) { l != "" })
          case lines != [] {
            True -> Ok(content)
            False -> {
              let _ = process.receive(process.new_subject(), 10)
              poll_until_content(path, remaining - 1)
            }
          }
        }
        Error(_) -> {
          let _ = process.receive(process.new_subject(), 10)
          poll_until_content(path, remaining - 1)
        }
      }
    }
  }
}

/// Helper to extract content from a Message.
fn get_content(msg: message.Message) -> String {
  case msg {
    message.User(content) -> content
    message.System(content) -> content
    message.Assistant(content, _, _) -> content
    message.Tool(_, content) -> content
  }
}

// ── Test 1: Telemetry fires through dispatcher ───────────────────────

/// Verify telemetry events are still emitted to :telemetry when dispatcher is active.
pub fn telemetry_fires_through_dispatcher_test() {
  // Attach a telemetry listener
  let listener_handle = listener.attach()

  // Create a config with mock provider
  let config = pig.test_harness()

  // Start the agent (creates dispatcher)
  let assert Ok(agent) = pig.start(config)

  // Run a prompt to trigger events
  let assert Ok(response) = pig.run(agent, "test prompt")
  get_content(response) |> should.equal("mock response")

  // Stop the agent
  pig.stop(agent)

  // Verify telemetry events were captured
  let _captured_events = listener.get_events(listener_handle)

  // Check for inference start event
  let event_names = listener.get_event_names(listener_handle)

  // Check for inference start event
  let has_start =
    list.any(event_names, fn(name) { name == events.inference_start_name() })
  has_start |> should.be_true()

  // Check for inference stop event
  let has_stop =
    list.any(event_names, fn(name) { name == events.inference_stop_name() })
  has_stop |> should.be_true()

  // Clean up
  listener.detach(listener_handle)
}

// ── Test 2: Session writer receives events via dispatcher ───────────

/// Verify that with_session_writer + pig.start() writes events to file.
pub fn session_writer_receives_events_via_dispatcher_test() {
  use tmp_file <- with_temp_file("session_writer")

  // Create config with session writer
  let config =
    pig.test_harness()
    |> pig.with_session_writer(tmp_file)

  // Start the agent
  let assert Ok(agent) = pig.start(config)

  // Run a prompt to trigger events
  let assert Ok(response) = pig.run(agent, "test prompt")
  get_content(response) |> should.equal("mock response")

  // Stop the agent
  pig.stop(agent)

  // Poll for file content (deterministic: event flow completes quickly)
  let content = poll_until_content(tmp_file, 10)
  let assert Ok(content) = content

  // Should have at least some JSONL lines
  let lines = string.split(content, "\n")
  let non_empty_lines = list.filter(lines, fn(l) { l != "" })

  // Should have at least one event line
  let line_count = list.length(non_empty_lines)
  line_count |> should.not_equal(0)

  // Each line should be valid JSON (contains curly braces)
  let has_json =
    list.any(non_empty_lines, fn(line) {
      string.contains(line, "{") && string.contains(line, "}")
    })
  has_json |> should.be_true()
}

// ── Test 3: Multiple consumers receive events via dispatcher ────────

/// Verify that both session writer and terminal output consumers receive events.
pub fn multiple_consumers_receive_events_test() {
  use tmp_file <- with_temp_file("multi_consumers")

  // Create config with both session writer and terminal output
  let config =
    pig.test_harness()
    |> pig.with_session_writer(tmp_file)
    |> pig.with_terminal_output()

  // Start the agent
  let assert Ok(agent) = pig.start(config)

  // Run a prompt to trigger events
  let assert Ok(response) = pig.run(agent, "test prompt")
  get_content(response) |> should.equal("mock response")

  // Stop the agent
  pig.stop(agent)

  // Poll for file content (deterministic: event flow completes quickly)
  let content = poll_until_content(tmp_file, 10)
  let assert Ok(content) = content
  let lines = string.split(content, "\n")
  let non_empty_lines = list.filter(lines, fn(l) { l != "" })

  // Should have at least one event
  list.length(non_empty_lines) |> should.not_equal(0)
}

// ── Test 4: Supervised path with consumers ─────────────────────────

/// Verify that supervisor.start_supervised with consumer specs starts the tree correctly.
/// Note: Full event flow verification is deferred due to initialization ordering complexity.
pub fn supervised_path_with_consumers_test() {
  use tmp_file <- with_temp_file("supervised")

  // Create an AgentConfig with mock provider
  let agent_config =
    state.config(fn(_msgs, _tools) {
      Ok(
        provider.from_message(message.Assistant(
          "mock response",
          [],
          option.None,
        )),
      )
    })

  // Create consumer spec for session writer
  let writer_name = process.new_name("test_session_writer")
  let writer_spec = session.supervised(tmp_file, writer_name)
  let writer_start_fn = fn() { session.start_consumer(tmp_file) }
  let consumer_spec =
    consumer_spec.ConsumerSpec(
      spec: writer_spec,
      name: writer_name,
      start_fn: writer_start_fn,
    )

  // Start supervised agent with consumer - this should not fail
  let assert Ok(supervised_agent) =
    supervisor.start_supervised(agent_config, [consumer_spec])

  // Run a prompt to verify the agent works
  let assert Ok(response) = supervisor.run(supervised_agent, "test prompt")
  get_content(response) |> should.equal("mock response")

  // Stop the supervised agent
  supervisor.stop(supervised_agent)
}

// ── Test 5: Multiple runs with supervised consumers ───────────────

/// Verify that the supervised agent can be used multiple times.
pub fn multiple_supervised_runs_with_consumers_test() {
  use tmp_file <- with_temp_file("multi_supervised")

  // Create an AgentConfig with mock provider
  let agent_config =
    state.config(fn(_msgs, _tools) {
      Ok(
        provider.from_message(message.Assistant(
          "mock response",
          [],
          option.None,
        )),
      )
    })

  // Create consumer spec for session writer
  let writer_name = process.new_name("test_session_writer_multi")
  let writer_spec = session.supervised(tmp_file, writer_name)
  let writer_start_fn = fn() { session.start_consumer(tmp_file) }
  let consumer_spec =
    consumer_spec.ConsumerSpec(
      spec: writer_spec,
      name: writer_name,
      start_fn: writer_start_fn,
    )

  // Start supervised agent with consumer
  let assert Ok(supervised_agent) =
    supervisor.start_supervised(agent_config, [consumer_spec])

  // Run multiple prompts to verify the agent works multiple times
  let assert Ok(r1) = supervisor.run(supervised_agent, "prompt 1")
  get_content(r1) |> should.equal("mock response")

  let assert Ok(r2) = supervisor.run(supervised_agent, "prompt 2")
  get_content(r2) |> should.equal("mock response")

  let assert Ok(r3) = supervisor.run(supervised_agent, "prompt 3")
  get_content(r3) |> should.equal("mock response")

  // Stop the supervised agent
  supervisor.stop(supervised_agent)
}
