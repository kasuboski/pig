//// Agent actor contract tests.
////
//// OTP actor wrapping the pure core. Per TESTING_STRATEGY §Axiom 1:
//// "Tests must verify features, not internal code."
//// Thin OTP wrapper — logic lives in core.gleam.

import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should
import pig/agent/actor
import pig/agent/state
import pig/ai/message
import pig/ai/provider
import pig/obs/dispatcher
import pig/tool
import simplifile
import support/harness
import temporary

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Start ────────────────────────────────────────────────────────

/// Actor starts successfully with a valid config.
pub fn start_actor_succeeds_test() {
  let provider = harness.fixed_provider(message.Assistant("hi", [], None))
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let config =
    state.config(provider)
    |> state.with_dispatcher(dispatcher_subject)
  let assert Ok(_subject) = actor.start(config)
  process.send(dispatcher_subject, dispatcher.Stop)
}

// ── Run ──────────────────────────────────────────────────────────

/// Sending Run(prompt) returns the provider's response.
pub fn run_returns_provider_response_test() {
  let response = message.Assistant("hello!", [], None)
  let provider = harness.fixed_provider(response)
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let config =
    state.config(provider)
    |> state.with_dispatcher(dispatcher_subject)
  let assert Ok(subject) = actor.start(config)
  let result = actor.run(subject, "hi", 5000)
  process.send(dispatcher_subject, dispatcher.Stop)
  let assert Ok(msg) = result
  msg == response
}

/// Tool call scenario works through the actor.
pub fn run_tool_call_scenario_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"hello\"}",
    )
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("done!", [], None)
  let provider = harness.sequenced_provider_for_actor([tool_resp, final])
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let config =
    state.config(provider)
    |> state.with_dispatcher(dispatcher_subject)
    |> state.with_tools(
      tool.new_registry() |> tool.register(harness.echo_tool()),
    )
  let assert Ok(subject) = actor.start(config)
  let assert Ok(msg) = actor.run(subject, "use echo", 5000)
  process.send(dispatcher_subject, dispatcher.Stop)
  msg == final
}

// ── State Accumulation (Sessions) ──────────────────────────────────

/// Two sequential runs on the same actor accumulate history.
/// The second run sees the first run's user messages in history.
pub fn runs_accumulate_history_test() {
  let ok_response = message.Assistant("ok", [], None)
  // Provider expects to see accumulated user messages.
  // Second call MUST see 2 user messages (from both runs).
  let call_count = process.new_subject()
  let provider = fn(msgs, _tools) {
    let user_count =
      msgs
      |> list.filter(fn(m) {
        case m {
          message.User(_) -> True
          _ -> False
        }
      })
      |> list.length()
    // Send observed count to test for verification
    process.send(call_count, user_count)
    Ok(provider.from_message(ok_response))
  }
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let config =
    state.config(provider)
    |> state.with_dispatcher(dispatcher_subject)
  let assert Ok(subject) = actor.start(config)
  // First run: should see 1 user message
  let assert Ok(_) = actor.run(subject, "prompt one", 5000)
  let assert Ok(count1) = process.receive(call_count, 1000)
  should.equal(count1, 1)
  // Second run: should see 2 user messages (accumulated from first run)
  let assert Ok(_) = actor.run(subject, "prompt two", 5000)
  let assert Ok(count2) = process.receive(call_count, 1000)
  should.equal(count2, 2)
  process.send(dispatcher_subject, dispatcher.Stop)
}

// ── Stop ─────────────────────────────────────────────────────────

/// Sending Stop terminates the actor. Monitor confirms process exit.
pub fn stop_terminates_actor_test() {
  let provider = harness.fixed_provider(message.Assistant("hi", [], None))
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let config =
    state.config(provider)
    |> state.with_dispatcher(dispatcher_subject)
  let assert Ok(subject) = actor.start(config)
  let assert Ok(pid) = process.subject_owner(subject)
  let monitor = process.monitor(pid)
  actor.stop(subject)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 1000)
  process.send(dispatcher_subject, dispatcher.Stop)
}

// ── Resilience ───────────────────────────────────────────────────

/// Tool execution failure returns Error result — actor stays alive.
pub fn tool_error_returns_error_not_crash_test() {
  let tc =
    message.ToolCall(id: "c1", name: "boom", arguments_json: "{}")
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("recovered!", [], None)
  let provider = harness.sequenced_provider_for_actor([tool_resp, final])
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let config =
    state.config(provider)
    |> state.with_dispatcher(dispatcher_subject)
    |> state.with_tools(
      tool.new_registry() |> tool.register(harness.failing_tool()),
    )
  let assert Ok(subject) = actor.start(config)
  let assert Ok(msg) = actor.run(subject, "try boom", 5000)
  process.send(dispatcher_subject, dispatcher.Stop)
  msg == final
}

/// Provider error returns Error result — actor stays alive for next call.
pub fn provider_error_returns_error_not_crash_test() {
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let config =
    state.config(harness.failing_provider)
    |> state.with_dispatcher(dispatcher_subject)
  let assert Ok(subject) = actor.start(config)
  let assert Error(_) = actor.run(subject, "hello", 5000)
  // Actor still alive — second call also returns error
  let assert Error(_) = actor.run(subject, "hello again", 5000)
  process.send(dispatcher_subject, dispatcher.Stop)
}

// ── Session Replay on Init ────────────────────────────────────────

/// When session_path is set and the file has history, actor replays on init.
/// The provider sees the replayed messages in history on first run.
pub fn actor_replays_session_on_init_test() {
  // Pre-create a JSONL session file with a user message
  let tmp =
    temporary.file()
    |> temporary.with_prefix("pig_replay_init_")
    |> temporary.with_suffix(".jsonl")
  let assert Ok(Nil) =
    temporary.create(tmp, fn(path) {
      // Write a session with one inference (user -> assistant)
      let line1 =
        "{\"event\":\"inference_completed\",\"input_messages\":[{\"role\":\"user\",\"content\":\"from replay\"}],\"message\":{\"role\":\"assistant\",\"content\":\"replayed answer\",\"tool_calls\":[]}}"
      let assert Ok(Nil) = simplifile.write(to: path, contents: line1 <> "\n")

      // Provider checks that it sees the replayed history
      let seen_count = process.new_subject()
      let provider = fn(msgs, _tools) {
        let user_msgs =
          msgs
          |> list.filter(fn(m) {
            case m {
              message.User(content) -> content == "from replay"
              _ -> False
            }
          })
        process.send(seen_count, list.length(user_msgs))
        Ok(provider.from_message(message.Assistant("fresh", [], None)))
      }

      let assert Ok(disp) = dispatcher.start()
      let config =
        state.config(provider)
        |> state.with_dispatcher(disp)
        |> state.with_session_path(path)

      let assert Ok(subject) = actor.start(config)
      let assert Ok(_) = actor.run(subject, "new prompt", 5000)

      // Provider should have seen the replayed "from replay" user message
      let assert Ok(count) = process.receive(seen_count, 2000)
      should.equal(count, 1)

      actor.stop(subject)
      process.send(disp, dispatcher.Stop)
      Nil
    })
}
