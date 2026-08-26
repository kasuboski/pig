import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/supervision
import gleam/string
import gleeunit
import pig
import pig/hooks
import pig/obs/consumer_spec
import pig/obs/events.{type SessionEvent, InferenceSettingsChanged}
import pig/obs/session
import pig/provider.{type InferenceRequest}
import pig/session_store
import pig_protocol/error
import pig_protocol/message
import pig_protocol/thinking
import simplifile
import support/harness
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

/// Configure and start Pig with a durable session store.
fn start_with_session_store(
  store: session_store.SessionStore,
  provider_fn: fn(InferenceRequest) ->
    Result(provider.InferenceResult, error.AiError),
) -> Result(pig.Agent, pig.StartError) {
  pig.new(provider.from_buffered(provider_fn))
  |> pig.with_session_store(store)
  |> pig.start
}

type CounterMessage {
  Increment(Subject(Nil))
  Count(Subject(Int))
}

fn start_counter() -> Subject(CounterMessage) {
  let builder = actor.new(0) |> actor.on_message(counter_handler)
  let assert Ok(started) = actor.start(builder)
  started.data
}

fn counter_handler(
  count: Int,
  msg: CounterMessage,
) -> actor.Next(Int, CounterMessage) {
  case msg {
    Increment(reply_to) -> {
      process.send(reply_to, Nil)
      actor.continue(count + 1)
    }
    Count(reply_to) -> {
      process.send(reply_to, count)
      actor.continue(count)
    }
  }
}

/// Synchronously record an operation before it completes.
fn increment_counter(counter: Subject(CounterMessage)) -> Nil {
  let reply_to = process.new_subject()
  process.send(counter, Increment(reply_to))
  let assert Ok(Nil) = process.receive(reply_to, 2000)
  Nil
}

fn counter_count(counter: Subject(CounterMessage)) -> Int {
  let reply_to = process.new_subject()
  process.send(counter, Count(reply_to))
  let assert Ok(count) = process.receive(reply_to, 2000)
  count
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

// ── Custom Consumer Tests ──────────────────────────────────────────────
//
// `add_consumer` and `with_consumer_specs` let a host runtime (e.g. yard)
// bridge pig's SessionEvent stream into its own store, correlated by
// run_id. These are the seam called out by the Pig Bridge work.

/// A consumer spec that captures every SessionEvent into a subject for
/// test assertions. Mirrors the shape a host runtime would build.
fn capturing_consumer_spec(
  capture: Subject(SessionEvent),
) -> consumer_spec.ConsumerSpec {
  let name = process.new_name("test_capture")
  let spec = supervision.worker(fn() { start_capture_named(capture, name) })
  let start_fn = fn() { start_capture(capture) }
  consumer_spec.ConsumerSpec(spec:, name:, start_fn:)
}

fn start_capture(
  capture: Subject(SessionEvent),
) -> Result(consumer_spec.StartedConsumer, actor.StartError) {
  Ok(consumer_spec.subject_endpoint(capture))
}

fn start_capture_named(
  capture: Subject(SessionEvent),
  name: process.Name(consumer_spec.SupervisedMessage),
) {
  let builder =
    actor.new(Nil)
    |> actor.on_message(capture_handler(capture))
    |> actor.named(name)
  case actor.start(builder) {
    Ok(started) -> Ok(actor.Started(data: Nil, pid: started.pid))
    Error(e) -> Error(e)
  }
}

fn capture_handler(
  capture: Subject(SessionEvent),
) -> fn(Nil, consumer_spec.SupervisedMessage) ->
  actor.Next(Nil, consumer_spec.SupervisedMessage) {
  fn(state, message) {
    case message {
      consumer_spec.Event(event) -> {
        process.send(capture, event)
        actor.continue(state)
      }
      consumer_spec.Stop(reply_to) -> {
        process.send(reply_to, Nil)
        actor.continue(state)
      }
    }
  }
}

// Test 4a: add_consumer registers a custom consumer that receives the first event
pub fn add_consumer_registers_custom_consumer_test() {
  let capture = process.new_subject()
  let spec = capturing_consumer_spec(capture)
  let config = pig.test_harness() |> pig.add_consumer(spec)

  let assert Ok(agent) = pig.start(config)
  // This is intentionally the first operation after startup. The event must
  // not race an asynchronous consumer registration.
  let assert Ok(_response) = pig.run(agent, "test")

  let assert Ok(event) = process.receive(capture, 2000)
  let assert events.InferenceStarted(..) = event

  pig.stop(agent)
}

// Test 4b: add_consumer accumulates alongside existing consumers
pub fn add_consumer_accumulates_with_existing_test() {
  let capture = process.new_subject()
  let spec = capturing_consumer_spec(capture)
  let config =
    pig.test_harness()
    |> pig.with_terminal_output()
    |> pig.add_consumer(spec)

  let assert Ok(agent) = pig.start(config)
  let assert Ok(_response) = pig.run(agent, "test")

  // The custom consumer still receives events despite the terminal
  // consumer also being registered — proving consumers accumulate.
  let assert Ok(_event) = process.receive(capture, 2000)

  pig.stop(agent)
}

// Test 4c: with_consumer_specs replaces the entire consumer list
pub fn with_consumer_specs_replaces_list_test() {
  let capture = process.new_subject()
  let spec = capturing_consumer_spec(capture)
  // Start with a session writer, then REPLACE it with only the capture spec.
  let config =
    pig.test_harness()
    |> pig.with_terminal_output()
    |> pig.with_consumer_specs([spec])

  let assert Ok(agent) = pig.start(config)
  let assert Ok(_response) = pig.run(agent, "test")

  // Only the capture consumer should be registered and receive events.
  let assert Ok(_event) = process.receive(capture, 2000)

  pig.stop(agent)
}

// Test 4d: with_consumer_specs with an empty list clears all consumers
pub fn with_consumer_specs_empty_clears_consumers_test() {
  let config =
    pig.test_harness()
    |> pig.with_terminal_output()
    |> pig.with_consumer_specs([])

  // Should start fine with no consumers.
  let assert Ok(agent) = pig.start(config)
  let assert Ok(response) = pig.run(agent, "test")
  assert get_content(response) == "mock response"
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
  let provider_fn = fn(request: InferenceRequest) {
    let msgs = request.messages
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
    pig.new(provider.from_buffered(provider_fn))
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
  let provider_fn = fn(request: InferenceRequest) {
    let msgs = request.messages
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
    pig.new(provider.from_buffered(provider_fn))
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

// ── Durable Session Store Tests ───────────────────────────────────

// Test 18: durable stores reject unpersisted initial history before side effects.
pub fn session_store_rejects_initial_history_before_load_or_provider_test() {
  let load_calls = start_counter()
  let provider_calls = start_counter()
  let store =
    session_store.SessionStore(
      load: fn() {
        increment_counter(load_calls)
        Ok(session_store.Session(option.None, [], option.None))
      },
      commit: fn(_commit) {
        Ok(session_store.Session(option.None, [], option.None))
      },
    )
  let provider_fn = fn(_request) {
    increment_counter(provider_calls)
    Ok(
      provider.from_message(message.Assistant(
        "unexpected",
        [],
        option.None,
        option.None,
      )),
    )
  }
  let config =
    pig.new(provider.from_buffered(provider_fn))
    |> pig.with_session_store(store)
    |> pig.with_initial_history([message.User("unpersisted")])

  let assert Error(pig.InvalidConfiguration(message)) = pig.start(config)
  assert message
    == "SessionStore cannot be combined with non-empty initial_history"
  assert counter_count(load_calls) == 0
  assert counter_count(provider_calls) == 0
}

// Test 19: session load failures prevent the provider from being used.
pub fn session_store_load_failure_prevents_provider_use_test() {
  let provider_calls = start_counter()
  let store =
    session_store.SessionStore(
      load: fn() { Error(session_store.Unavailable("offline")) },
      commit: fn(_commit) {
        Ok(session_store.Session(option.None, [], option.None))
      },
    )
  let provider_fn = fn(_request) {
    increment_counter(provider_calls)
    Ok(
      provider.from_message(message.Assistant(
        "unexpected",
        [],
        option.None,
        option.None,
      )),
    )
  }

  let assert Error(pig.SessionLoad(session_store.Unavailable("offline"))) =
    start_with_session_store(store, provider_fn)
  assert counter_count(provider_calls) == 0
}

// Test 20: a loaded terminal assistant is retained and returned without inference.
pub fn session_store_loaded_terminal_assistant_continues_without_provider_test() {
  let provider_calls = start_counter()
  let completed =
    message.Assistant("already complete", [], option.None, option.None)
  let loaded_history = [message.User("previous question"), completed]
  let store =
    session_store.SessionStore(
      load: fn() {
        Ok(session_store.Session(
          option.Some("loaded-head"),
          loaded_history,
          option.None,
        ))
      },
      commit: fn(_commit) {
        Ok(session_store.Session(option.None, [], option.None))
      },
    )
  let provider_fn = fn(_request) {
    increment_counter(provider_calls)
    Ok(
      provider.from_message(message.Assistant(
        "unexpected",
        [],
        option.None,
        option.None,
      )),
    )
  }

  let assert Ok(agent) = start_with_session_store(store, provider_fn)
  assert pig.history(agent) == loaded_history
  let assert Ok(response) = pig.run_continue(agent)
  assert response == completed
  assert counter_count(provider_calls) == 0
  pig.stop(agent)
}

// Test 21: continuing loaded user history commits only the new assistant delta.
pub fn session_store_continue_commits_only_new_assistant_delta_test() {
  let commits = process.new_subject()
  let commit_counter = start_counter()
  let provider_messages = process.new_subject()
  let provider_calls = start_counter()
  let loaded_history = [message.User("resume from here")]
  let final = message.Assistant("continued", [], option.None, option.None)
  let store =
    session_store.SessionStore(
      load: fn() {
        Ok(session_store.Session(
          option.Some("loaded-head"),
          loaded_history,
          option.None,
        ))
      },
      commit: fn(commit) {
        increment_counter(commit_counter)
        process.send(commits, commit)
        Ok(session_store.Session(
          option.Some(commit.id),
          harness.messages_in_commit(commit),
          option.None,
        ))
      },
    )
  let provider_fn = fn(request: InferenceRequest) {
    let messages = request.messages
    increment_counter(provider_calls)
    process.send(provider_messages, messages)
    Ok(provider.from_message(final))
  }

  let assert Ok(agent) = start_with_session_store(store, provider_fn)
  let assert Ok(response) = pig.run_continue(agent)
  assert response == final
  let assert Ok(messages) = process.receive(provider_messages, 2000)
  assert messages == loaded_history
  let assert Ok(commit) = process.receive(commits, 2000)
  assert commit.parent == option.Some("loaded-head")
  assert harness.messages_in_commit(commit) == [final]
  assert counter_count(commit_counter) == 1
  assert counter_count(provider_calls) == 1
  assert pig.history(agent) == list.append(loaded_history, [final])
  pig.stop(agent)
}

/// A standalone JSONL restart restores persisted settings ahead of config.
pub fn standalone_jsonl_restart_restores_settings_test() {
  use path <- with_temp_file("jsonl_settings_restart")
  let restored = provider.with_thinking_level(thinking.High)
  let configured = provider.with_thinking_level(thinking.Low)
  let assert Ok(Nil) =
    simplifile.write(
      path,
      session.format_event(InferenceSettingsChanged(settings: restored)) <> "\n",
    )
  let seen = process.new_subject()
  let provider_fn = fn(request: InferenceRequest) {
    process.send(seen, request.settings)
    Ok(
      provider.from_message(message.Assistant(
        "ok",
        [],
        option.None,
        option.None,
      )),
    )
  }
  let config =
    pig.new(provider.from_buffered(provider_fn))
    |> pig.with_thinking_level(thinking.Low)
    |> pig.with_session_writer(path)
  let assert Ok(agent) = pig.start(config)
  let assert Ok(_) = pig.run(agent, "restart")
  let assert Ok(actual) = process.receive(seen, 1000)
  assert actual == restored
  assert configured != restored
  pig.stop(agent)
}
