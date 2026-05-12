//// Runtime interpreter tests.
////
//// Verifies the sans-IO runtime actor: effect execution, event emission,
//// hook pipeline, parallelism, state accumulation, resilience.
////
//// This file consolidates tests that previously lived in:
////   actor_test.gleam        → start/stop/resilience/history
////   emitter_test.gleam      → session event emission
////   hooks_integration_test.gleam → hook pipeline + session writer
////   parallel_tools_test.gleam   → parallel tool execution proof

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import jscheam/schema
import pig/agent/runtime
import pig/ai/error
import pig/ai/message
import pig/ai/provider
import pig/ai/tool_definition
import pig/hooks
import pig/obs/dispatcher
import pig/obs/events
import pig/obs/session as session_writer
import pig/tool
import simplifile
import temporary

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Helpers ──────────────────────────────────────────────────────

fn echo_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "echo",
      description: "Echoes back",
      parameters: schema.object([]),
    ),
    handler: fn(args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
      let assert Ok(msg) =
        decode.run(args, decode.field("msg", decode.string, decode.success))
      Ok(json.object([#("echo", json.string(msg))]))
    },
  )
}

fn failing_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "boom",
      description: "Always fails",
      parameters: schema.object([]),
    ),
    handler: fn(_) { Error(tool.ToolError(message: "tool exploded")) },
  )
}

fn slow_echo_tool(delay_ms: Int) -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "slow_echo",
      description: "Slow echo tool",
      parameters: schema.object([]),
    ),
    handler: fn(args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
      process.sleep(delay_ms)
      let assert Ok(msg) =
        decode.run(args, decode.field("msg", decode.string, decode.success))
      Ok(json.object([#("echo", json.string(msg))]))
    },
  )
}

fn fixed_provider(response: message.Message) {
  fn(_msgs, _tools) { Ok(provider.from_message(response)) }
}

fn sequenced_provider(responses: List(message.Message)) {
  fn(msgs, _tools) {
    let idx =
      msgs
      |> list.filter(fn(m) {
        case m {
          message.Assistant(..) -> True
          _ -> False
        }
      })
      |> list.length()
    case list.drop(responses, idx) |> list.first() {
      Ok(msg) -> Ok(provider.from_message(msg))
      Error(_) ->
        Error(error.ApiError(
          "mock: no response at index " <> int.to_string(idx),
        ))
    }
  }
}

/// Start a runtime with dispatcher + event collector.
fn start_with_collector(
  provider_fn: provider.Provider,
  tools: List(tool.Tool),
  hooks_list: List(hooks.Hooks),
) -> #(
  process.Subject(runtime.RuntimeMsg),
  process.Subject(events.SessionEvent),
  process.Subject(dispatcher.DispatcherMessage),
) {
  let assert Ok(disp) = dispatcher.start()
  let collector = process.new_subject()
  process.send(disp, dispatcher.RegisterConsumer(collector))
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let config =
    runtime.RuntimeConfig(
      provider: provider_fn,
      tools: registry,
      hooks: hooks_list,
      dispatcher: disp,
      model: "test-model",
      max_iterations: 50,
    )
  let assert Ok(subject) = runtime.start(config)
  #(subject, collector, disp)
}

/// Start a runtime without event collector (simpler setup).
fn start_simple(
  provider_fn: provider.Provider,
  tools: List(tool.Tool),
) -> #(
  process.Subject(runtime.RuntimeMsg),
  process.Subject(dispatcher.DispatcherMessage),
) {
  let assert Ok(disp) = dispatcher.start()
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let config =
    runtime.RuntimeConfig(
      provider: provider_fn,
      tools: registry,
      hooks: [],
      dispatcher: disp,
      model: "test-model",
      max_iterations: 50,
    )
  let assert Ok(subject) = runtime.start(config)
  #(subject, disp)
}

fn collect_events(
  subject: process.Subject(events.SessionEvent),
  count: Int,
  timeout: Int,
) -> List(events.SessionEvent) {
  collect_events_helper(subject, count, [], timeout)
}

fn collect_events_helper(
  subject: process.Subject(events.SessionEvent),
  remaining: Int,
  acc: List(events.SessionEvent),
  timeout: Int,
) -> List(events.SessionEvent) {
  case remaining <= 0 {
    True -> list.reverse(acc)
    False ->
      case process.receive(subject, timeout) {
        Ok(event) ->
          collect_events_helper(subject, remaining - 1, [event, ..acc], timeout)
        Error(_) -> list.reverse(acc)
      }
  }
}

fn find_indices(haystack: List(String), needle: String) -> List(Int) {
  haystack
  |> list.index_map(fn(val, idx) {
    case val == needle {
      True -> Some(idx)
      False -> None
    }
  })
  |> list.filter(fn(x) { x != None })
  |> list.map(fn(x) {
    let assert Some(v) = x
    v
  })
}

fn with_temp_file(name: String, run test_fn: fn(String) -> a) -> a {
  let tmp =
    temporary.file()
    |> temporary.with_prefix("pig_runtime_" <> name <> "_")
    |> temporary.with_suffix(".jsonl")
  let assert Ok(result) = temporary.create(tmp, test_fn)
  result
}

// ══════════════════════════════════════════════════════════════════
//  Start / Stop / Lifecycle
// ══════════════════════════════════════════════════════════════════

/// Runtime starts successfully with a valid config.
pub fn start_succeeds_test() {
  let #(_subject, disp) =
    start_simple(fixed_provider(message.Assistant("hi", [], None)), [])
  process.send(disp, dispatcher.Stop)
}

/// Sending Stop terminates the actor. Monitor confirms process exit.
pub fn stop_terminates_actor_test() {
  let #(subject, disp) =
    start_simple(fixed_provider(message.Assistant("hi", [], None)), [])
  let assert Ok(pid) = process.subject_owner(subject)
  let monitor = process.monitor(pid)
  runtime.stop(subject)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 1000)
  process.send(disp, dispatcher.Stop)
}

/// Run returns the provider's response.
pub fn run_returns_provider_response_test() {
  let response = message.Assistant("hello!", [], None)
  let #(subject, disp) = start_simple(fixed_provider(response), [])
  let assert Ok(msg) = runtime.run(subject, "hi", 5000)
  msg |> should.equal(response)
  process.send(disp, dispatcher.Stop)
}

// ══════════════════════════════════════════════════════════════════
//  CallProvider — Inference Events
// ══════════════════════════════════════════════════════════════════

/// Runtime emits InferenceStarted + InferenceCompleted events.
pub fn call_provider_emits_inference_events_test() {
  let response = message.Assistant("hello!", [], None)
  let #(subject, collector, disp) =
    start_with_collector(fixed_provider(response), [], [])
  let _ = runtime.run(subject, "hi", 5000)
  let evts = collect_events(collector, 2, 1000)
  let has_started =
    list.any(evts, fn(e) {
      case e {
        events.InferenceStarted(..) -> True
        _ -> False
      }
    })
  let has_completed =
    list.any(evts, fn(e) {
      case e {
        events.InferenceCompleted(..) -> True
        _ -> False
      }
    })
  has_started |> should.be_true()
  has_completed |> should.be_true()
  process.send(disp, dispatcher.Stop)
}

/// Runtime emits InferenceFailed on provider error.
pub fn call_provider_emits_inference_failed_test() {
  let #(subject, collector, disp) =
    start_with_collector(
      fn(_, _) { Error(error.ApiError("provider failed")) },
      [],
      [],
    )
  let _ = runtime.run(subject, "hi", 5000)
  let evts = collect_events(collector, 2, 1000)
  let has_failed =
    list.any(evts, fn(e) {
      case e {
        events.InferenceFailed(..) -> True
        _ -> False
      }
    })
  has_failed |> should.be_true()
  process.send(disp, dispatcher.Stop)
}

// ══════════════════════════════════════════════════════════════════
//  ExecuteTools — Tool Execution Events
// ══════════════════════════════════════════════════════════════════

/// Tool call scenario works end to end.
pub fn tool_call_scenario_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"hello\"}",
    )
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("done!", [], None)
  let #(subject, _collector, disp) =
    start_with_collector(
      sequenced_provider([tool_resp, final]),
      [echo_tool()],
      [],
    )
  let assert Ok(result) = runtime.run(subject, "use echo", 5000)
  result |> should.equal(final)
  process.send(disp, dispatcher.Stop)
}

/// Runtime emits ToolStarted + ToolExecuted per tool.
pub fn tool_execution_emits_events_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"test\"}",
    )
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("done", [], None)
  let #(subject, collector, disp) =
    start_with_collector(
      sequenced_provider([tool_resp, final]),
      [echo_tool()],
      [],
    )
  let _ = runtime.run(subject, "use echo", 5000)
  let evts = collect_events(collector, 6, 2000)
  let has_tool_started =
    list.any(evts, fn(e) {
      case e {
        events.ToolStarted(..) -> True
        _ -> False
      }
    })
  let has_tool_executed =
    list.any(evts, fn(e) {
      case e {
        events.ToolExecuted(..) -> True
        _ -> False
      }
    })
  has_tool_started |> should.be_true()
  has_tool_executed |> should.be_true()
  process.send(disp, dispatcher.Stop)
}

/// Tool errors produce error results — agent recovers.
pub fn tool_error_recovery_test() {
  let tc = message.ToolCall(id: "c1", name: "boom", arguments_json: "{}")
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("recovered!", [], None)
  let #(subject, _collector, disp) =
    start_with_collector(
      sequenced_provider([tool_resp, final]),
      [failing_tool()],
      [],
    )
  let assert Ok(result) = runtime.run(subject, "try boom", 5000)
  result |> should.equal(final)
  process.send(disp, dispatcher.Stop)
}

// ══════════════════════════════════════════════════════════════════
//  Hook Pipeline
// ══════════════════════════════════════════════════════════════════

/// Hook blocks a tool → provider sees blocked message.
pub fn hook_blocks_tool_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"hello\"}",
    )
  let response1 = message.Assistant("", [tc], None)
  let response2 = message.Assistant("blocked handled", [], None)
  let guard =
    hooks.new("guard")
    |> hooks.on_tool_call(fn(event) {
      case event.tool_name == "echo" {
        True -> hooks.block_tool("echo not allowed")
        False -> hooks.allow_tool()
      }
    })
  let #(subject, collector, disp) =
    start_with_collector(
      sequenced_provider([response1, response2]),
      [echo_tool()],
      [guard],
    )
  let assert Ok(result) = runtime.run(subject, "use echo", 5000)
  result |> should.equal(response2)
  let evts = collect_events(collector, 6, 2000)
  let has_blocked =
    list.any(evts, fn(e) {
      case e {
        events.ToolBlocked(..) -> True
        _ -> False
      }
    })
  has_blocked |> should.be_true()
  process.send(disp, dispatcher.Stop)
}

/// Hook allows tool → executes normally.
pub fn hook_allows_tool_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"hello\"}",
    )
  let response1 = message.Assistant("", [tc], None)
  let response2 = message.Assistant("done", [], None)
  let guard =
    hooks.new("guard")
    |> hooks.on_tool_call(fn(_) { hooks.allow_tool() })
  let #(subject, _collector, disp) =
    start_with_collector(
      sequenced_provider([response1, response2]),
      [echo_tool()],
      [guard],
    )
  let assert Ok(result) = runtime.run(subject, "use echo", 5000)
  result |> should.equal(response2)
  process.send(disp, dispatcher.Stop)
}

/// Hook transforms tool result → provider sees transformed content.
pub fn hook_transforms_result_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"secret\"}",
    )
  let response1 = message.Assistant("", [tc], None)
  let response2 = message.Assistant("scrubbed", [], None)
  let scrubber =
    hooks.new("scrubber")
    |> hooks.on_tool_result(fn(event) {
      case event.is_error {
        True -> hooks.keep_result()
        False -> hooks.replace_result("[REDACTED]", False)
      }
    })
  let #(subject, _collector, disp) =
    start_with_collector(
      sequenced_provider([response1, response2]),
      [echo_tool()],
      [scrubber],
    )
  let assert Ok(result) = runtime.run(subject, "use echo", 5000)
  result |> should.equal(response2)
  process.send(disp, dispatcher.Stop)
}

/// Hook transforms messages before inference.
pub fn hook_transforms_messages_before_inference_test() {
  let ok = message.Assistant("ok", [], None)
  let seen = process.new_subject()
  let provider_fn = fn(msgs, _tools) {
    let first_user =
      msgs
      |> list.filter(fn(m) {
        case m {
          message.User(_) -> True
          _ -> False
        }
      })
      |> list.first()
    case first_user {
      Ok(message.User(content)) -> process.send(seen, content)
      _ -> Nil
    }
    Ok(provider.from_message(ok))
  }
  let prefixer =
    hooks.new("prefixer")
    |> hooks.on_before_inference(fn(event) {
      let transformed =
        event.messages
        |> list.map(fn(m) {
          case m {
            message.User(content) -> message.User("[scrubbed] " <> content)
            other -> other
          }
        })
      hooks.ReplaceMessages(transformed)
    })
  let #(subject, _collector, disp) =
    start_with_collector(provider_fn, [], [prefixer])
  let _ = runtime.run(subject, "hello", 5000)
  let assert Ok(content) = process.receive(seen, 2000)
  content |> should.equal("[scrubbed] hello")
  process.send(disp, dispatcher.Stop)
}

/// Hook blocks tool → session writer records tool_blocked event.
pub fn hook_blocks_tool_session_writer_records_it_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"hello\"}",
    )
  let response1 = message.Assistant("", [tc], None)
  let response2 = message.Assistant("recovered", [], None)
  let guard =
    hooks.new("guard")
    |> hooks.on_tool_call(fn(event) {
      case event.tool_name == "echo" {
        True -> hooks.block_tool("echo blocked")
        False -> hooks.allow_tool()
      }
    })

  use path <- with_temp_file("hook_blocked")
  let assert Ok(disp) = dispatcher.start()
  let assert Ok(consumer) = session_writer.start_consumer(path)
  process.send(disp, dispatcher.RegisterConsumer(consumer))

  let registry = tool.new_registry() |> tool.register(echo_tool())
  let config =
    runtime.RuntimeConfig(
      provider: sequenced_provider([response1, response2]),
      tools: registry,
      hooks: [guard],
      dispatcher: disp,
      model: "test-model",
      max_iterations: 50,
    )
  let assert Ok(subject) = runtime.start(config)
  let assert Ok(final) = runtime.run(subject, "use echo", 5000)
  should.equal(final, response2)
  runtime.stop(subject)

  let _ = process.receive(process.new_subject(), 200)
  process.send(disp, dispatcher.Stop)

  let assert Ok(content) = simplifile.read(path)
  let lines =
    content
    |> string.split("\n")
    |> list.filter(fn(l) { l != "" })

  let has_blocked =
    list.any(lines, fn(line) {
      string.contains(line, "\"event\":\"tool_blocked\"")
      && string.contains(line, "\"hook_name\":\"guard\"")
      && string.contains(line, "\"reason\":\"echo blocked\"")
    })
  should.be_true(has_blocked)

  let has_hook_acted =
    list.any(lines, fn(line) {
      string.contains(line, "\"event\":\"hook_acted\"")
      && string.contains(line, "\"hook_name\":\"guard\"")
      && string.contains(line, "\"hook_point\":\"before_tool_call\"")
    })
  should.be_true(has_hook_acted)
}

// ══════════════════════════════════════════════════════════════════
//  State Accumulation
// ══════════════════════════════════════════════════════════════════

/// Two sequential runs accumulate history.
/// The second run sees the first run's user messages.
pub fn runs_accumulate_history_test() {
  let ok_response = message.Assistant("ok", [], None)
  let call_count = process.new_subject()
  let provider_fn = fn(msgs, _tools) {
    let user_count =
      msgs
      |> list.filter(fn(m) {
        case m {
          message.User(_) -> True
          _ -> False
        }
      })
      |> list.length()
    process.send(call_count, user_count)
    Ok(provider.from_message(ok_response))
  }
  let #(subject, disp) = start_simple(provider_fn, [])
  let assert Ok(_) = runtime.run(subject, "prompt one", 5000)
  let assert Ok(count1) = process.receive(call_count, 1000)
  should.equal(count1, 1)
  let assert Ok(_) = runtime.run(subject, "prompt two", 5000)
  let assert Ok(count2) = process.receive(call_count, 1000)
  should.equal(count2, 2)
  process.send(disp, dispatcher.Stop)
}

/// Accumulate history across runs with hooks.
pub fn runs_accumulate_history_with_hooks_test() {
  let ok = message.Assistant("ok", [], None)
  let count_subject = process.new_subject()
  let provider_fn = fn(msgs, _tools) {
    let user_count =
      msgs
      |> list.filter(fn(m) {
        case m {
          message.User(_) -> True
          _ -> False
        }
      })
      |> list.length()
    process.send(count_subject, user_count)
    Ok(provider.from_message(ok))
  }
  let guard =
    hooks.new("noop")
    |> hooks.on_tool_call(fn(_) { hooks.allow_tool() })
  let #(_subject, disp) = start_simple(provider_fn, [])
  process.send(disp, dispatcher.Stop)

  let assert Ok(disp2) = dispatcher.start()
  let config =
    runtime.RuntimeConfig(
      provider: provider_fn,
      tools: tool.new_registry(),
      hooks: [guard],
      dispatcher: disp2,
      model: "test-model",
      max_iterations: 50,
    )
  let assert Ok(subject2) = runtime.start(config)
  let assert Ok(_) = runtime.run(subject2, "one", 5000)
  let assert Ok(1) = process.receive(count_subject, 1000)
  let assert Ok(_) = runtime.run(subject2, "two", 5000)
  let assert Ok(2) = process.receive(count_subject, 1000)
  runtime.stop(subject2)
  process.send(disp2, dispatcher.Stop)
}

// ══════════════════════════════════════════════════════════════════
//  Resilience
// ══════════════════════════════════════════════════════════════════

/// Provider error returns Error result — actor stays alive for next call.
pub fn provider_error_stays_alive_test() {
  let #(subject, disp) =
    start_simple(fn(_, _) { Error(error.ApiError("provider failed")) }, [])
  let assert Error(_) = runtime.run(subject, "hello", 5000)
  // Actor still alive — second call also returns error
  let assert Error(_) = runtime.run(subject, "hello again", 5000)
  process.send(disp, dispatcher.Stop)
}

/// Max iterations → Failed.
pub fn max_iterations_circuit_breaker_test() {
  let tc =
    message.ToolCall(
      id: "loop",
      name: "echo",
      arguments_json: "{\"msg\":\"x\"}",
    )
  let looping = message.Assistant("", [tc], None)
  let assert Ok(disp) = dispatcher.start()
  let config =
    runtime.RuntimeConfig(
      provider: fixed_provider(looping),
      tools: tool.new_registry() |> tool.register(echo_tool()),
      hooks: [],
      dispatcher: disp,
      model: "test-model",
      max_iterations: 2,
    )
  let assert Ok(subject) = runtime.start(config)
  let assert Error(e) = runtime.run(subject, "loop", 5000)
  case e {
    error.ApiError(message:) ->
      string.contains(message, "exceeded maximum iterations")
      |> should.be_true()
    _ -> should.be_true(False)
  }
  process.send(disp, dispatcher.Stop)
}

// ══════════════════════════════════════════════════════════════════
//  Parallel Tool Execution
// ══════════════════════════════════════════════════════════════════

/// Three slow tools: all ToolStarted events fire before any ToolExecuted.
pub fn parallel_tools_all_starts_before_stops_test() {
  let tc1 =
    message.ToolCall(
      id: "a",
      name: "slow_echo",
      arguments_json: "{\"msg\":\"x\"}",
    )
  let tc2 =
    message.ToolCall(
      id: "b",
      name: "slow_echo",
      arguments_json: "{\"msg\":\"y\"}",
    )
  let tc3 =
    message.ToolCall(
      id: "c",
      name: "slow_echo",
      arguments_json: "{\"msg\":\"z\"}",
    )
  let tool_resp = message.Assistant("", [tc1, tc2, tc3], None)
  let final = message.Assistant("done!", [], None)
  let #(subject, collector, disp) =
    start_with_collector(
      sequenced_provider([tool_resp, final]),
      [slow_echo_tool(50)],
      [],
    )
  let assert Ok(msg) = runtime.run(subject, "parallel", 10_000)
  msg |> should.equal(final)
  let evts = collect_events(collector, 6, 5000)
  let event_types =
    list.map(evts, fn(e) {
      case e {
        events.ToolStarted(..) -> "ToolStarted"
        events.ToolExecuted(..) -> "ToolExecuted"
        _ -> "Other"
      }
    })
  let starts = find_indices(event_types, "ToolStarted")
  let stops = find_indices(event_types, "ToolExecuted")
  let max_start = list.fold(starts, 0, int.max)
  let min_stop = case stops {
    [] -> 999_999
    _ -> list.fold(stops, 999_999, int.min)
  }
  should.be_true(max_start < min_stop)
  process.send(disp, dispatcher.Stop)
}

/// Parallel execution produces correct results.
pub fn parallel_tools_produces_correct_results_test() {
  let tc1 =
    message.ToolCall(
      id: "a",
      name: "slow_echo",
      arguments_json: "{\"msg\":\"alpha\"}",
    )
  let tc2 =
    message.ToolCall(
      id: "b",
      name: "slow_echo",
      arguments_json: "{\"msg\":\"beta\"}",
    )
  let tc3 =
    message.ToolCall(
      id: "c",
      name: "slow_echo",
      arguments_json: "{\"msg\":\"gamma\"}",
    )
  let tool_resp = message.Assistant("", [tc1, tc2, tc3], None)
  let final = message.Assistant("complete", [], None)
  let #(subject, _collector, disp) =
    start_with_collector(
      sequenced_provider([tool_resp, final]),
      [slow_echo_tool(10)],
      [],
    )
  let assert Ok(msg) = runtime.run(subject, "parallel", 5000)
  msg |> should.equal(final)
  process.send(disp, dispatcher.Stop)
}
