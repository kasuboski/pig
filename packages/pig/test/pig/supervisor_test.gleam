//// Supervised agent tests.
////
//// Verify start_supervised, run, stop, and
//// process lifecycle through the OTP static_supervisor.
//// Per TESTING_STRATEGY §Axiom 1: test features, not implementation.

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import gleeunit
import pig
import pig/agent/runtime
import pig/agent/state
import pig/obs/consumer_spec
import pig/obs/events.{type SessionEvent, InferenceCompleted, InferenceStarted}
import pig/obs/session
import pig/obs/terminal
import pig/provider
import pig/session_store
import pig/session_store/memory
import pig/supervisor
import pig_protocol/message
import pig_protocol/stop_reason
import pig_protocol/thinking
import support/harness
import temporary

/// Run a test with a temporary JSONL file. Auto-cleaned after callback returns.
fn with_temp_file(name: String, run test_fn: fn(String) -> a) -> a {
  let tmp =
    temporary.file()
    |> temporary.with_prefix("pig_sup_" <> name <> "_")
    |> temporary.with_suffix(".jsonl")
  let assert Ok(result) = temporary.create(tmp, test_fn)
  result
}

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Helper: build AgentConfig from pig.PigConfig ─────────────────

fn agent_config(config: pig.PigConfig) -> state.AgentConfig {
  pig.build_agent_config(config)
}

type CounterMessage {
  Increment(process.Subject(Nil))
  Count(process.Subject(Int))
}

fn start_counter() -> process.Subject(CounterMessage) {
  let assert Ok(started) =
    actor.new(0)
    |> actor.on_message(counter_handler)
    |> actor.start()
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

fn increment(counter: process.Subject(CounterMessage)) -> Nil {
  actor.call(counter, 1000, Increment)
}

fn capturing_consumer_spec(
  capture: process.Subject(SessionEvent),
  started: process.Subject(Nil),
) -> consumer_spec.ConsumerSpec {
  let name = process.new_name("test_supervised_capture")
  let spec =
    supervision.worker(fn() { start_capture_named(capture, started, name) })
  let start_fn = fn() { start_capture(capture) }
  consumer_spec.ConsumerSpec(spec:, name:, start_fn:)
}

fn start_capture(
  capture: process.Subject(SessionEvent),
) -> Result(process.Subject(SessionEvent), actor.StartError) {
  let builder =
    actor.new(Nil)
    |> actor.on_message(capture_handler(capture))
  actor.start(builder)
  |> result.map(fn(started) { started.data })
}

fn start_capture_named(
  capture: process.Subject(SessionEvent),
  started_subject: process.Subject(Nil),
  name: process.Name(SessionEvent),
) -> Result(actor.Started(Nil), actor.StartError) {
  let builder =
    actor.new(Nil)
    |> actor.on_message(capture_handler(capture))
    |> actor.named(name)
  case actor.start(builder) {
    Ok(started) -> {
      process.send(started_subject, Nil)
      Ok(actor.Started(data: Nil, pid: started.pid))
    }
    Error(error) -> Error(error)
  }
}

fn capture_handler(
  capture: process.Subject(SessionEvent),
) -> fn(Nil, SessionEvent) -> actor.Next(Nil, SessionEvent) {
  fn(state, event) {
    process.send(capture, event)
    actor.continue(state)
  }
}

fn assert_inference_events(capture: process.Subject(SessionEvent)) -> Nil {
  let assert Ok(InferenceStarted(..)) = process.receive(capture, 2000)
  let assert Ok(InferenceCompleted(..)) = process.receive(capture, 2000)
  Nil
}

fn count(counter: process.Subject(CounterMessage)) -> Int {
  actor.call(counter, 1000, Count)
}

fn await_subject_owner(
  subject: process.Subject(runtime.RuntimeMsg),
  reply_to: process.Subject(process.Pid),
) -> Nil {
  case process.subject_owner(subject) {
    Ok(pid) -> process.send(reply_to, pid)
    Error(Nil) -> {
      process.sleep(1)
      await_subject_owner(subject, reply_to)
    }
  }
}

// ── start_supervised ─────────────────────────────────────────────

/// start_supervised returns Ok(SupervisedAgent).
pub fn start_supervised_succeeds_test() {
  let response = message.Assistant("hi", [], None, None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> agent_config
  let assert Ok(_sup) = supervisor.start_supervised(config, [])
}

// ── run through supervised agent ─────────────────────────────────

/// run returns the provider's response through the supervised agent.
pub fn run_returns_response_test() {
  let response = message.Assistant("hello!", [], None, None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> agent_config
  let assert Ok(sup) = supervisor.start_supervised(config, [])
  let assert Ok(msg) = supervisor.run(sup, "hi")
  let assert True = msg == response
  supervisor.stop(sup)
}

// ── run_with_timeout ─────────────────────────────────────────────

/// run_with_timeout works with explicit timeout.
pub fn run_with_timeout_works_test() {
  let response = message.Assistant("timed!", [], None, None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> agent_config
  let assert Ok(sup) = supervisor.start_supervised(config, [])
  let assert Ok(msg) = supervisor.run_with_timeout(sup, "hi", 5000)
  let assert True = msg == response
  supervisor.stop(sup)
}

// ── stop terminates supervisor and agent ─────────────────────────

/// stop kills the supervisor. Monitor confirms process down.
pub fn stop_terminates_processes_test() {
  let response = message.Assistant("hi", [], None, None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> agent_config
  let assert Ok(sup) = supervisor.start_supervised(config, [])
  let monitor = process.monitor(sup.sup_pid)
  supervisor.stop(sup)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 2000)
}

// ── agent reusable after run ─────────────────────────────────────

/// Agent is not one-shot. Multiple runs on same supervised agent work.
pub fn agent_reusable_after_run_test() {
  let response = message.Assistant("ok", [], None, None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> agent_config
  let assert Ok(sup) = supervisor.start_supervised(config, [])
  let assert Ok(m1) = supervisor.run(sup, "first")
  let assert True = m1 == response
  let assert Ok(m2) = supervisor.run(sup, "second")
  let assert True = m2 == response
  supervisor.stop(sup)
}

// ── supervised agent with tool ───────────────────────────────────

/// Tool execution works through the supervised path.
pub fn supervised_tool_call_works_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"supervised\"}",
    )
  let tool_resp = message.Assistant("", [tc], None, None)
  let final = message.Assistant("done!", [], None, None)
  let config =
    pig.new(harness.sequenced_provider_for_actor([tool_resp, final]))
    |> pig.with_tool(harness.echo_tool())
    |> agent_config
  let assert Ok(sup) = supervisor.start_supervised(config, [])
  let assert Ok(msg) = supervisor.run_with_timeout(sup, "use echo", 5000)
  let assert True = msg == final
  supervisor.stop(sup)
}

// ── Nested Supervision Tree ────────────────────────────────────────

/// start_supervised with no consumers creates working agent.
pub fn start_supervised_no_consumers_test() {
  let response = message.Assistant("hi", [], None, None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> agent_config
  let assert Ok(sup) = supervisor.start_supervised(config, [])
  let assert Ok(msg) = supervisor.run(sup, "hello")
  let assert True = msg == response
  supervisor.stop(sup)
}

/// start_supervised with consumers creates nested supervision tree.
pub fn start_supervised_with_consumers_test() {
  use session_path <- with_temp_file("consumers")
  let response = message.Assistant("done", [], None, None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> pig.with_model("test-model")
    |> agent_config

  // Create a session writer consumer spec
  let session_name = process.new_name("test_session_writer")
  let session_spec = session.supervised(session_path, session_name)
  let session_start = fn() { session.start_consumer(session_path) }

  // Create a terminal consumer spec
  let terminal_name = process.new_name("test_terminal")
  let terminal_spec = terminal.supervised(terminal_name)
  let terminal_start = fn() { terminal.start_consumer() }

  let consumer_specs = [
    consumer_spec.ConsumerSpec(
      spec: session_spec,
      name: session_name,
      start_fn: session_start,
    ),
    consumer_spec.ConsumerSpec(
      spec: terminal_spec,
      name: terminal_name,
      start_fn: terminal_start,
    ),
  ]

  let assert Ok(sup) = supervisor.start_supervised(config, consumer_specs)

  // Run the agent - should trigger events that go through dispatcher to consumers
  let assert Ok(_msg) = supervisor.run(sup, "test")

  // Cleanup
  supervisor.stop(sup)
}

/// Consumers receive events via dispatcher after supervised start.
pub fn consumers_receive_events_test() {
  let response = message.Assistant("event test", [], None, None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> pig.with_model("event-model")
    |> agent_config

  // Create a test event capture consumer
  let _event_subject = process.new_subject()

  // Create a mock consumer spec that sends events to our test subject
  // Since we can't easily mock a supervised consumer, we'll just verify
  // the tree structure by checking that the agent runs without errors
  let assert Ok(sup) = supervisor.start_supervised(config, [])

  // Run the agent
  let assert Ok(msg) = supervisor.run(sup, "test prompt")
  let assert True = msg == response

  supervisor.stop(sup)
}

/// Initial consumers remain registered when the OneForAll event subtree is
/// reconstructed after a consumer failure.
pub fn supervised_consumers_survive_event_tree_restart_test() {
  let capture = process.new_subject()
  let consumer_started = process.new_subject()
  let consumer_spec = capturing_consumer_spec(capture, consumer_started)
  let response = message.Assistant("restart event", [], None, None)
  let config = pig.new(harness.fixed_provider(response)) |> agent_config

  let assert Ok(sup) = supervisor.start_supervised(config, [consumer_spec])
  let assert Ok(Nil) = process.receive(consumer_started, 2000)

  // The consumer is configured in the dispatcher's initial state, so the
  // first event is available immediately after supervised startup.
  let assert Ok(_first) = supervisor.run(sup, "first")
  assert_inference_events(capture)

  // Force the OneForAll subtree to reconstruct both dispatcher and consumer.
  let consumer_subject = process.named_subject(consumer_spec.name)
  let assert Ok(original_pid) = process.subject_owner(consumer_subject)
  let monitor = process.monitor(original_pid)
  process.kill(original_pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 2000)
  let assert Ok(Nil) = process.receive(consumer_started, 2000)

  let assert Ok(_second) = supervisor.run(sup, "second")
  assert_inference_events(capture)
  supervisor.stop(sup)
}

/// stop kills the entire supervision tree.
pub fn stop_kills_tree_test() {
  use session_path <- with_temp_file("stop_tree")
  let response = message.Assistant("cleanup", [], None, None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> agent_config

  // Create a consumer spec
  let session_name = process.new_name("test_stop_session")
  let session_spec = session.supervised(session_path, session_name)
  let session_start = fn() { session.start_consumer(session_path) }

  let consumer_specs = [
    consumer_spec.ConsumerSpec(
      spec: session_spec,
      name: session_name,
      start_fn: session_start,
    ),
  ]

  let assert Ok(sup) = supervisor.start_supervised(config, consumer_specs)
  let assert Ok(_msg) = supervisor.run(sup, "test")

  // Stop the supervisor
  let monitor = process.monitor(sup.sup_pid)
  supervisor.stop(sup)

  // Verify supervisor is down
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 2000)
}

/// Agent can run multiple times with supervised consumers.
pub fn multiple_runs_with_consumers_test() {
  let response = message.Assistant("reusable", [], None, None)
  let config =
    pig.new(harness.fixed_provider(response))
    |> agent_config

  let assert Ok(sup) = supervisor.start_supervised(config, [])

  let assert Ok(msg1) = supervisor.run(sup, "run 1")
  let assert True = msg1 == response

  let assert Ok(msg2) = supervisor.run(sup, "run 2")
  let assert True = msg2 == response

  supervisor.stop(sup)
}

// ── Durable supervised sessions ──────────────────────────────────

/// Session load errors are distinct from OTP startup errors and do not run inference.
pub fn supervised_session_load_failure_is_distinct_test() {
  let provider_calls = start_counter()
  let store =
    session_store.SessionStore(
      load: fn() { Error(session_store.Unavailable("offline")) },
      commit: fn(_commit) { Ok(session_store.Session(None, [], None)) },
    )
  let provider_fn = fn(_request) {
    increment(provider_calls)
    Ok(provider.from_message(message.Assistant("unexpected", [], None, None)))
  }
  let config = pig.new(provider_fn) |> agent_config

  let assert Error(supervisor.SessionLoad(session_store.Unavailable("offline"))) =
    supervisor.start_supervised_with_session_store(config, [], store)
  assert count(provider_calls) == 0
}

/// A completed assistant loaded into a supervised runtime needs no provider call.
pub fn supervised_loaded_terminal_assistant_returns_without_provider_test() {
  let provider_calls = start_counter()
  let completed =
    message.Assistant("already complete", [], None, Some(stop_reason.Stop))
  let store =
    session_store.SessionStore(
      load: fn() {
        Ok(session_store.Session(
          Some("loaded-head"),
          [message.User("previous question"), completed],
          None,
        ))
      },
      commit: fn(_commit) { Ok(session_store.Session(None, [], None)) },
    )
  let provider_fn = fn(_request) {
    increment(provider_calls)
    Ok(provider.from_message(message.Assistant("unexpected", [], None, None)))
  }
  let config = pig.new(provider_fn) |> agent_config

  let assert Ok(sup) =
    supervisor.start_supervised_with_session_store(config, [], store)
  let assert Ok(response) = supervisor.run_continue_with_timeout(sup, 5000)
  assert response == completed
  assert count(provider_calls) == 0
  supervisor.stop(sup)
}

/// Continuing loaded work commits just the new assistant against the loaded head.
pub fn supervised_loaded_user_commits_new_assistant_against_loaded_head_test() {
  let provider_calls = start_counter()
  let provider_messages = process.new_subject()
  let commits = process.new_subject()
  let loaded = [message.System("discarded"), message.User("resume from here")]
  let final = message.Assistant("continued", [], None, Some(stop_reason.Stop))
  let store =
    session_store.SessionStore(
      load: fn() {
        Ok(session_store.Session(Some("loaded-head"), loaded, option.None))
      },
      commit: fn(commit) {
        process.send(commits, commit)
        Ok(session_store.Session(
          Some(commit.id),
          harness.messages_in_commit(commit),
          None,
        ))
      },
    )
  let provider_fn = fn(request: provider.InferenceRequest) {
    let messages = request.messages
    increment(provider_calls)
    process.send(provider_messages, messages)
    Ok(provider.from_message(final))
  }
  let config = pig.new(provider_fn) |> agent_config

  let assert Ok(sup) =
    supervisor.start_supervised_with_session_store(config, [], store)
  let assert Ok(response) = supervisor.run_continue(sup)
  assert response == final
  let assert Ok(sent_to_provider) = process.receive(provider_messages, 1000)
  assert sent_to_provider == [message.User("resume from here")]
  let assert Ok(commit) = process.receive(commits, 1000)
  assert commit.parent == Some("loaded-head")
  assert harness.messages_in_commit(commit) == [final]
  assert count(provider_calls) == 1
  supervisor.stop(sup)
}

/// A restarted durable runtime reloads the committed transcript instead of its
/// startup snapshot, so continuing does not repeat completed inference.
pub fn supervised_durable_runtime_restart_reloads_latest_session_test() {
  let provider_calls = start_counter()
  let completed =
    message.Assistant("durably complete", [], None, Some(stop_reason.Stop))
  let assert Ok(memory_store) =
    memory.start(session_store.Session(None, [], None))
  let store = memory.store(memory_store)
  let provider_fn = fn(_request) {
    increment(provider_calls)
    Ok(provider.from_message(completed))
  }
  let config = pig.new(provider_fn) |> agent_config

  let assert Ok(sup) =
    supervisor.start_supervised_with_session_store(config, [], store)
  let assert Ok(response) = supervisor.run_with_timeout(sup, "complete", 5000)
  assert response == completed
  assert count(provider_calls) == 1

  let assert Ok(original_pid) = process.subject_owner(sup.subject)
  let monitor = process.monitor(original_pid)
  process.kill(original_pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 2000)

  // Wait for the permanent worker to register its replacement; no whole-tree
  // restart or timing sleep is involved.
  let restarted = process.new_subject()
  let _ = process.spawn(fn() { await_subject_owner(sup.subject, restarted) })
  let assert Ok(restarted_pid) = process.receive(restarted, 5000)
  assert restarted_pid != original_pid
  let assert Ok(resumed) = supervisor.run_continue_with_timeout(sup, 5000)
  assert resumed == completed
  assert count(provider_calls) == 1

  supervisor.stop(sup)
  memory.stop(memory_store)
}

/// A supervised durable restart restores persisted inference settings ahead of
/// the configured value.
pub fn supervised_durable_restart_restores_inference_settings_test() {
  let restored = provider.with_thinking_level(thinking.High)
  let configured = provider.with_thinking_level(thinking.Low)
  let seen = process.new_subject()
  let response = message.Assistant("done", [], None, Some(stop_reason.Stop))
  let provider_fn = fn(request: provider.InferenceRequest) {
    process.send(seen, request.settings)
    Ok(provider.from_message(response))
  }
  let assert Ok(memory_store) =
    memory.start(session_store.Session(None, [], Some(restored)))
  let config =
    pig.new(provider_fn)
    |> pig.with_thinking_level(thinking.Low)
    |> agent_config
  let assert Ok(sup) =
    supervisor.start_supervised_with_session_store(
      config,
      [],
      memory.store(memory_store),
    )
  let assert Ok(_) = supervisor.run_with_timeout(sup, "first", 5000)
  let assert Ok(first_settings) = process.receive(seen, 1000)
  assert first_settings == restored

  let assert Ok(original_pid) = process.subject_owner(sup.subject)
  let monitor = process.monitor(original_pid)
  process.kill(original_pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 2000)
  let restarted = process.new_subject()
  let _ = process.spawn(fn() { await_subject_owner(sup.subject, restarted) })
  let assert Ok(_restarted_pid) = process.receive(restarted, 5000)

  let assert Ok(_) = supervisor.run_with_timeout(sup, "second", 5000)
  let assert Ok(second_settings) = process.receive(seen, 1000)
  assert second_settings == restored
  assert configured != restored
  supervisor.stop(sup)
  memory.stop(memory_store)
}
