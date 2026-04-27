//// Agent actor contract tests.
////
//// OTP actor wrapping the pure core. Per TESTING_STRATEGY §Axiom 1:
//// "Tests must verify features, not internal code." Per PLAN Task 6.1:
//// thin OTP wrapper — logic lives in core.gleam.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleeunit
import pig/agent/actor
import pig/agent/state
import pig/ai/error
import pig/ai/message
import pig/tool
import support/harness

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Start ────────────────────────────────────────────────────────

/// Actor starts successfully with a valid config.
pub fn start_actor_succeeds_test() {
  let provider = harness.fixed_provider(message.Assistant("hi", [], None))
  let config = state.config(provider)
  let assert Ok(_subject) = actor.start(config)
}

// ── Run ──────────────────────────────────────────────────────────

/// Sending Run(prompt) returns the provider's response.
pub fn run_returns_provider_response_test() {
  let response = message.Assistant("hello!", [], None)
  let provider = harness.fixed_provider(response)
  let config = state.config(provider)
  let assert Ok(subject) = actor.start(config)
  let result = actor.run(subject, "hi", 5000)
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
  let config =
    state.config(provider)
    |> state.with_tools(
      tool.new_registry() |> tool.register(harness.echo_tool()),
    )
  let assert Ok(subject) = actor.start(config)
  let assert Ok(msg) = actor.run(subject, "use echo", 5000)
  msg == final
}

// ── State Isolation ──────────────────────────────────────────────

/// Two sequential runs on the same actor start from fresh state.
/// The second run does NOT see history from the first.
pub fn runs_are_state_isolated_test() {
  // Provider counts user messages. If history bleeds between runs,
  // second call would see 2 user messages (run1's + run2's).
  let ok_response = message.Assistant("ok", [], None)
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
    case user_count == 1 {
      True -> Ok(ok_response)
      False ->
        Error(error.ApiError(
          "history bleed! saw " <> int.to_string(user_count)
            <> " user messages",
        ))
    }
  }
  let config = state.config(provider)
  let assert Ok(subject) = actor.start(config)
  // First run succeeds
  let assert Ok(m1) = actor.run(subject, "prompt one", 5000)
  let assert True = m1 == ok_response
  // Second run also succeeds — no history from first run
  let assert Ok(m2) = actor.run(subject, "prompt two", 5000)
  let assert True = m2 == ok_response
}

// ── Stop ─────────────────────────────────────────────────────────

/// Sending Stop terminates the actor. Monitor confirms process exit.
pub fn stop_terminates_actor_test() {
  let provider = harness.fixed_provider(message.Assistant("hi", [], None))
  let config = state.config(provider)
  let assert Ok(subject) = actor.start(config)
  let assert Ok(pid) = process.subject_owner(subject)
  let monitor = process.monitor(pid)
  actor.stop(subject)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 1000)
}

// ── Resilience ───────────────────────────────────────────────────

/// Tool execution failure returns Error result — actor stays alive.
pub fn tool_error_returns_error_not_crash_test() {
  let tc =
    message.ToolCall(id: "c1", name: "boom", arguments_json: "{}")
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("recovered!", [], None)
  let provider = harness.sequenced_provider_for_actor([tool_resp, final])
  let config =
    state.config(provider)
    |> state.with_tools(
      tool.new_registry() |> tool.register(harness.failing_tool()),
    )
  let assert Ok(subject) = actor.start(config)
  let assert Ok(msg) = actor.run(subject, "try boom", 5000)
  msg == final
}

/// Provider error returns Error result — actor stays alive for next call.
pub fn provider_error_returns_error_not_crash_test() {
  let config = state.config(harness.failing_provider)
  let assert Ok(subject) = actor.start(config)
  let assert Error(_) = actor.run(subject, "hello", 5000)
  // Actor still alive — second call also returns error
  let assert Error(_) = actor.run(subject, "hello again", 5000)
}
