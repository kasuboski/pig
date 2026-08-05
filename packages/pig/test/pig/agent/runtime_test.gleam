//// Runtime interpreter tests.
////
//// Verifies the sans-IO runtime actor: effect execution, event emission,
//// hook pipeline, parallelism, state accumulation, resilience.
////

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import gleeunit
import jscheam/schema
import pig/agent/runtime
import pig/agent/state
import pig/hooks
import pig/obs/dispatcher
import pig/obs/events
import pig/obs/session as session_writer
import pig/provider
import pig/run_error
import pig/session_store
import pig/session_store/memory
import pig/tool
import pig_protocol/error
import pig_protocol/message
import pig_protocol/stop_reason
import pig_protocol/thinking
import pig_protocol/tool_definition
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
    handler: fn(_, args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
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
    handler: fn(_, _) { Error(tool.ToolError(message: "tool exploded")) },
  )
}

fn slow_echo_tool(delay_ms: Int) -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "slow_echo",
      description: "Slow echo tool",
      parameters: schema.object([]),
    ),
    handler: fn(_, args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
      process.sleep(delay_ms)
      let assert Ok(msg) =
        decode.run(args, decode.field("msg", decode.string, decode.success))
      Ok(json.object([#("echo", json.string(msg))]))
    },
  )
}

fn context_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "context",
      description: "Reports invocation context",
      parameters: schema.object([]),
    ),
    handler: fn(context, _) {
      Ok(
        json.object([
          #("id", json.string(tool.call_id(context))),
          #("name", json.string(tool.tool_name(context))),
        ]),
      )
    },
  )
}

fn messages_in_commit(
  commit: session_store.SessionCommit,
) -> List(message.Message) {
  let session_store.SessionCommit(delta:, ..) = commit
  case delta {
    session_store.MessagesAppended(messages) -> messages
    session_store.InferenceSettingsChanged(_) -> []
  }
}

fn fixed_provider(response: message.Message) {
  fn(_request: provider.InferenceRequest) {
    Ok(provider.from_message(response))
  }
}

fn sequenced_provider(responses: List(message.Message)) {
  fn(request: provider.InferenceRequest) {
    let msgs = request.messages
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
      inference_settings: provider.default_settings(),
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
      inference_settings: provider.default_settings(),
    )
  let assert Ok(subject) = runtime.start(config)
  #(subject, disp)
}

/// Start a runtime whose transitions are durably committed to `store`.
fn start_with_session_store(
  provider_fn: provider.Provider,
  tools: List(tool.Tool),
  store: session_store.SessionStore,
  loaded_head: option.Option(String),
) -> #(
  process.Subject(runtime.RuntimeMsg),
  process.Subject(dispatcher.DispatcherMessage),
) {
  let assert Ok(disp) = dispatcher.start()
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let agent_config =
    state.config(provider_fn)
    |> state.with_tools(registry)
    |> state.with_model("test-model")
    |> state.with_max_iterations(50)
  let config =
    runtime.RuntimeConfig(
      provider: provider_fn,
      tools: registry,
      hooks: [],
      dispatcher: disp,
      model: "test-model",
      max_iterations: 50,
      inference_settings: agent_config.inference_settings,
    )
  let initial_state =
    runtime.RuntimeState(
      agent_state: state.new(agent_config),
      config:,
      session: runtime.SessionReady(store, loaded_head),
      inference_settings: agent_config.inference_settings,
    )
  let assert Ok(subject) = runtime.start_with_state(config, initial_state)
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

/// Drain all events preceding an explicit dispatcher barrier without assuming
/// an event count. The barrier itself is excluded.
fn collect_events_before_barrier(
  subject: process.Subject(events.SessionEvent),
) -> List(events.SessionEvent) {
  let assert Ok(event) = process.receive(subject, 1000)
  case event {
    events.SessionEnded(events.Interrupted) -> []
    _ -> [event, ..collect_events_before_barrier(subject)]
  }
}

fn is_tool_execution_event(event: events.SessionEvent) -> Bool {
  case event {
    events.ToolStarted(..)
    | events.ToolExecuted(..)
    | events.ToolBlocked(..)
    | events.HookActed(..) -> True
    _ -> False
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

type CounterMessage {
  Increment
  Count(process.Subject(Int))
  StopCounter
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
  message: CounterMessage,
) -> actor.Next(Int, CounterMessage) {
  case message {
    Increment -> actor.continue(count + 1)
    Count(reply_to) -> {
      process.send(reply_to, count)
      actor.continue(count)
    }
    StopCounter -> actor.stop()
  }
}

fn count(counter: process.Subject(CounterMessage)) -> Int {
  let reply_to = process.new_subject()
  process.send(counter, Count(reply_to))
  let assert Ok(value) = process.receive(reply_to, 1000)
  value
}

fn stop_counter(counter: process.Subject(CounterMessage)) -> Nil {
  process.send(counter, StopCounter)
}

type StoreControlMessage {
  Next(process.Subject(Bool))
}

type SettingsFailureControlMessage {
  NextSettingsFailure(process.Subject(session_store.SessionError))
}

fn start_store_control(
  commands: List(Bool),
) -> process.Subject(StoreControlMessage) {
  let assert Ok(started) =
    actor.new(commands)
    |> actor.on_message(store_control_handler)
    |> actor.start()
  started.data
}

fn store_control_handler(
  commands: List(Bool),
  message: StoreControlMessage,
) -> actor.Next(List(Bool), StoreControlMessage) {
  let Next(reply_to) = message
  let assert [next, ..rest] = commands
  process.send(reply_to, next)
  actor.continue(rest)
}

fn controlled_store(
  control: process.Subject(StoreControlMessage),
  commits: process.Subject(session_store.SessionCommit),
) -> session_store.SessionStore {
  session_store.SessionStore(
    load: fn() { Ok(session_store.Session(None, [], None)) },
    commit: fn(commit) {
      process.send(commits, commit)
      case actor.call(control, 1000, Next) {
        True ->
          Ok(session_store.Session(
            Some(commit.id),
            messages_in_commit(commit),
            None,
          ))
        False -> Error(session_store.Unavailable("offline"))
      }
    },
  )
}

/// Returns an unrelated head after successful commits, modelling another writer
/// advancing the session before the caller observes the commit result.
fn start_settings_failure_control(
  failures: List(session_store.SessionError),
) -> process.Subject(SettingsFailureControlMessage) {
  let assert Ok(started) =
    actor.new(failures)
    |> actor.on_message(settings_failure_control_handler)
    |> actor.start()
  started.data
}

fn settings_failure_control_handler(
  failures: List(session_store.SessionError),
  message: SettingsFailureControlMessage,
) -> actor.Next(List(session_store.SessionError), SettingsFailureControlMessage) {
  let NextSettingsFailure(reply_to) = message
  let assert [failure, ..rest] = failures
  process.send(reply_to, failure)
  actor.continue(rest)
}

fn settings_failure_store(
  failures: process.Subject(SettingsFailureControlMessage),
  commits: process.Subject(session_store.SessionCommit),
) -> session_store.SessionStore {
  session_store.SessionStore(
    load: fn() {
      Ok(session_store.Session(
        Some("old-head"),
        [],
        Some(provider.default_settings()),
      ))
    },
    commit: fn(commit) {
      process.send(commits, commit)
      case commit.delta {
        session_store.InferenceSettingsChanged(_) -> {
          Error(actor.call(failures, 1000, NextSettingsFailure))
        }
        session_store.MessagesAppended(messages) ->
          Ok(session_store.Session(
            Some(commit.id),
            messages,
            Some(provider.default_settings()),
          ))
      }
    },
  )
}

fn foreign_head_controlled_store(
  control: process.Subject(StoreControlMessage),
  commits: process.Subject(session_store.SessionCommit),
  foreign_head: String,
) -> session_store.SessionStore {
  session_store.SessionStore(
    load: fn() { Ok(session_store.Session(None, [], None)) },
    commit: fn(commit) {
      process.send(commits, commit)
      case actor.call(control, 1000, Next) {
        True ->
          Ok(session_store.Session(
            Some(foreign_head),
            messages_in_commit(commit),
            None,
          ))
        False -> Error(session_store.Unavailable("offline"))
      }
    },
  )
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
    start_simple(fixed_provider(message.Assistant("hi", [], None, None)), [])
  process.send(disp, dispatcher.Stop)
}

/// Sending Stop terminates the actor. Monitor confirms process exit.
pub fn stop_terminates_actor_test() {
  let #(subject, disp) =
    start_simple(fixed_provider(message.Assistant("hi", [], None, None)), [])
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
  let response = message.Assistant("hello!", [], None, None)
  let #(subject, disp) = start_simple(fixed_provider(response), [])
  let assert Ok(msg) = runtime.run(subject, "hi", 5000)
  assert msg == response
  process.send(disp, dispatcher.Stop)
}

// ══════════════════════════════════════════════════════════════════
//  CallProvider — Inference Events
// ══════════════════════════════════════════════════════════════════

/// Runtime emits InferenceStarted + InferenceCompleted events.
pub fn call_provider_emits_inference_events_test() {
  let response = message.Assistant("hello!", [], None, None)
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
  assert has_started
  assert has_completed
  process.send(disp, dispatcher.Stop)
}

/// Runtime emits InferenceFailed on provider error.
pub fn call_provider_emits_inference_failed_test() {
  let #(subject, collector, disp) =
    start_with_collector(
      fn(_request: provider.InferenceRequest) {
        Error(error.ApiError("provider failed"))
      },
      [],
      [],
    )
  let _ = runtime.run(subject, "hi", 5000)
  let evts = collect_events(collector, 2, 1000)
  let assert [
    events.InferenceStarted(model:, ..),
    events.InferenceFailed(model: failed_model, ..),
  ] = evts
  assert model == "test-model"
  assert failed_model == "test-model"
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
  let tool_resp = message.Assistant("", [tc], None, None)
  let final = message.Assistant("done!", [], None, None)
  let #(subject, _collector, disp) =
    start_with_collector(
      sequenced_provider([tool_resp, final]),
      [echo_tool()],
      [],
    )
  let assert Ok(result) = runtime.run(subject, "use echo", 5000)
  assert result == final
  process.send(disp, dispatcher.Stop)
}

/// Check a rejected batch has no tool or hook side effects and produces one
/// ordered structured error result for every input call.
fn check_invalid_tool_call_batch(
  calls: List(message.ToolCall),
  batch_error: tool.ToolCallBatchError,
) -> Nil {
  let tool_response = message.Assistant("", calls, None, None)
  let final = message.Assistant("done", [], None, None)
  let handler_calls = start_counter()
  let hook_calls = start_counter()
  let hook =
    hooks.new("must-not-run")
    |> hooks.on_tool_call(fn(_) {
      process.send(hook_calls, Increment)
      hooks.BlockTool("hook ran")
    })
  let #(subject, collector, disp) =
    start_with_collector(
      sequenced_provider([tool_response, final]),
      [counted_echo_tool(handler_calls)],
      [hook],
    )

  let assert Ok(result) = runtime.run(subject, "go", 5000)
  assert result == final
  assert count(handler_calls) == 0
  assert count(hook_calls) == 0

  let expected_results =
    list.map(calls, fn(call) {
      message.Tool(
        tool_call_id: call.id,
        content: "Tool error: "
          <> tool.error_message(tool.InvalidToolCallBatch(batch_error)),
      )
    })
  let actual_results =
    runtime.history(subject, 5000)
    |> list.filter(fn(message) {
      case message {
        message.Tool(..) -> True
        _ -> False
      }
    })
  assert actual_results == expected_results

  // A dispatcher barrier proves all earlier runtime events are observable
  // without coupling this assertion to a particular total event count.
  process.send(disp, dispatcher.Event(events.SessionEnded(events.Interrupted)))
  let events = collect_events_before_barrier(collector)
  assert list.filter(events, is_tool_execution_event) == []

  process.send(disp, dispatcher.Stop)
  stop_counter(handler_calls)
  stop_counter(hook_calls)
}

/// Empty IDs reject the entire batch before hooks, events, or handlers.
pub fn empty_id_tool_call_batch_skips_hooks_and_handlers_test() {
  check_invalid_tool_call_batch(
    [
      message.ToolCall(id: "valid", name: "echo", arguments_json: "{}"),
      message.ToolCall(id: "", name: "echo", arguments_json: "{}"),
    ],
    tool.EmptyToolCallId(1),
  )
}

/// Duplicate IDs reject the entire batch before hooks, events, or handlers.
pub fn duplicate_id_tool_call_batch_skips_hooks_and_handlers_test() {
  check_invalid_tool_call_batch(
    [
      message.ToolCall(id: "duplicate", name: "echo", arguments_json: "{}"),
      message.ToolCall(id: "duplicate", name: "echo", arguments_json: "{}"),
    ],
    tool.DuplicateToolCallId("duplicate"),
  )
}

/// Runtime emits ToolStarted + ToolExecuted per tool.
pub fn tool_execution_emits_events_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"test\"}",
    )
  let tool_resp = message.Assistant("", [tc], None, None)
  let final = message.Assistant("done", [], None, None)
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
  assert has_tool_started
  assert has_tool_executed
  process.send(disp, dispatcher.Stop)
}

/// Tool errors produce error results — agent recovers.
pub fn tool_error_recovery_test() {
  let tc = message.ToolCall(id: "c1", name: "boom", arguments_json: "{}")
  let tool_resp = message.Assistant("", [tc], None, None)
  let final = message.Assistant("recovered!", [], None, None)
  let #(subject, _collector, disp) =
    start_with_collector(
      sequenced_provider([tool_resp, final]),
      [failing_tool()],
      [],
    )
  let assert Ok(result) = runtime.run(subject, "try boom", 5000)
  assert result == final
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
  let response1 = message.Assistant("", [tc], None, None)
  let response2 = message.Assistant("blocked handled", [], None, None)
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
  assert result == response2
  let evts = collect_events(collector, 6, 2000)
  let has_blocked =
    list.any(evts, fn(e) {
      case e {
        events.ToolBlocked(..) -> True
        _ -> False
      }
    })
  assert has_blocked
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
  let response1 = message.Assistant("", [tc], None, None)
  let response2 = message.Assistant("done", [], None, None)
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
  assert result == response2
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
  let response1 = message.Assistant("", [tc], None, None)
  let response2 = message.Assistant("scrubbed", [], None, None)
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
  assert result == response2
  process.send(disp, dispatcher.Stop)
}

/// Hook transforms messages before inference.
pub fn hook_transforms_messages_before_inference_test() {
  let ok = message.Assistant("ok", [], None, None)
  let seen = process.new_subject()
  let provider_fn = fn(request: provider.InferenceRequest) {
    let msgs = request.messages
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
  assert content == "[scrubbed] hello"
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
  let response1 = message.Assistant("", [tc], None, None)
  let response2 = message.Assistant("recovered", [], None, None)
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
      inference_settings: provider.default_settings(),
    )
  let assert Ok(subject) = runtime.start(config)
  let assert Ok(final) = runtime.run(subject, "use echo", 5000)
  assert final == response2
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
  assert has_blocked

  let has_hook_acted =
    list.any(lines, fn(line) {
      string.contains(line, "\"event\":\"hook_acted\"")
      && string.contains(line, "\"hook_name\":\"guard\"")
      && string.contains(line, "\"hook_point\":\"before_tool_call\"")
    })
  assert has_hook_acted
}

// ══════════════════════════════════════════════════════════════════
//  State Accumulation
// ══════════════════════════════════════════════════════════════════

/// Two sequential runs accumulate history.
/// The second run sees the first run's user messages.
pub fn runs_accumulate_history_test() {
  let ok_response = message.Assistant("ok", [], None, None)
  let call_count = process.new_subject()
  let provider_fn = fn(request: provider.InferenceRequest) {
    let msgs = request.messages
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
  assert count1 == 1
  let assert Ok(_) = runtime.run(subject, "prompt two", 5000)
  let assert Ok(count2) = process.receive(call_count, 1000)
  assert count2 == 2
  process.send(disp, dispatcher.Stop)
}

/// Accumulate history across runs with hooks.
pub fn runs_accumulate_history_with_hooks_test() {
  let ok = message.Assistant("ok", [], None, None)
  let count_subject = process.new_subject()
  let provider_fn = fn(request: provider.InferenceRequest) {
    let msgs = request.messages
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
      inference_settings: provider.default_settings(),
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
    start_simple(
      fn(_request: provider.InferenceRequest) {
        Error(error.ApiError("provider failed"))
      },
      [],
    )
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
  let looping = message.Assistant("", [tc], None, None)
  let assert Ok(disp) = dispatcher.start()
  let config =
    runtime.RuntimeConfig(
      provider: fixed_provider(looping),
      tools: tool.new_registry() |> tool.register(echo_tool()),
      hooks: [],
      dispatcher: disp,
      model: "test-model",
      max_iterations: 2,
      inference_settings: provider.default_settings(),
    )
  let assert Ok(subject) = runtime.start(config)
  let assert Error(e) = runtime.run(subject, "loop", 5000)
  let assert run_error.Inference(error.ApiError(message:)) = e
  assert string.contains(message, "exceeded maximum iterations")
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
  let tool_resp = message.Assistant("", [tc1, tc2, tc3], None, None)
  let final = message.Assistant("done!", [], None, None)
  let #(subject, collector, disp) =
    start_with_collector(
      sequenced_provider([tool_resp, final]),
      [slow_echo_tool(50)],
      [],
    )
  let assert Ok(msg) = runtime.run(subject, "parallel", 10_000)
  assert msg == final
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
  assert max_start < min_stop
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
  let tool_resp = message.Assistant("", [tc1, tc2, tc3], None, None)
  let final = message.Assistant("complete", [], None, None)
  let #(subject, _collector, disp) =
    start_with_collector(
      sequenced_provider([tool_resp, final]),
      [slow_echo_tool(10)],
      [],
    )
  let assert Ok(msg) = runtime.run(subject, "parallel", 5000)
  assert msg == final
  process.send(disp, dispatcher.Stop)
}

// ══════════════════════════════════════════════════════════════════
//  Durable Session Commits
// ══════════════════════════════════════════════════════════════════

/// A terminal run commits its user prompt followed by its assistant reply.
pub fn session_terminal_run_commits_ordered_transitions_test() {
  let commits = process.new_subject()
  let commit_count = start_counter()
  let store =
    session_store.SessionStore(
      load: fn() { Ok(session_store.Session(None, [], None)) },
      commit: fn(commit) {
        process.send(commits, commit)
        process.send(commit_count, Increment)
        Ok(session_store.Session(
          Some(commit.id),
          messages_in_commit(commit),
          None,
        ))
      },
    )
  let reply = message.Assistant("hello", [], None, None)
  let #(subject, disp) =
    start_with_session_store(fixed_provider(reply), [], store, None)

  let assert Ok(reply) = runtime.run(subject, "hi", 5000)
  let assert [first, second] = [
    process.receive(commits, 1000),
    process.receive(commits, 1000),
  ]
  let assert Ok(first_commit) = first
  let assert Ok(second_commit) = second
  assert messages_in_commit(first_commit) == [message.User("hi")]
  assert messages_in_commit(second_commit) == [reply]
  assert second_commit.parent == Some(first_commit.id)
  assert count(commit_count) == 2

  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

/// A rejected user commit prevents inference and leaves runtime history unchanged.
pub fn session_user_commit_failure_prevents_inference_test() {
  let provider_called = start_counter()
  let store =
    session_store.SessionStore(
      load: fn() { Ok(session_store.Session(None, [], None)) },
      commit: fn(commit) {
        case messages_in_commit(commit) {
          [message.User(_)] -> Error(session_store.Unavailable("offline"))
          _ ->
            Ok(session_store.Session(
              Some(commit.id),
              messages_in_commit(commit),
              None,
            ))
        }
      },
    )
  let provider_fn = fn(_request: provider.InferenceRequest) {
    process.send(provider_called, Increment)
    Ok(provider.from_message(message.Assistant("unexpected", [], None, None)))
  }
  let #(subject, disp) = start_with_session_store(provider_fn, [], store, None)

  let assert Error(run_error.Session(session_store.Unavailable("offline"))) =
    runtime.run(subject, "hi", 5000)
  assert runtime.history(subject, 1000) == []
  assert count(provider_called) == 0

  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

/// A successful commit reporting another head does not make its candidate current.
pub fn session_commit_success_with_different_head_stays_pending_test() {
  let commits = process.new_subject()
  let control = start_store_control([True])
  let provider_calls = start_counter()
  let provider_fn = fn(_request: provider.InferenceRequest) {
    process.send(provider_calls, Increment)
    Ok(provider.from_message(message.Assistant("unexpected", [], None, None)))
  }
  let #(subject, disp) =
    start_with_session_store(
      provider_fn,
      [],
      foreign_head_controlled_store(control, commits, "newer-head"),
      None,
    )

  let assert Error(run_error.Session(session_store.ParentConflict(
    expected:,
    actual:,
  ))) = runtime.run(subject, "first", 5000)
  let assert Ok(commit) = process.receive(commits, 1000)
  assert expected == Some(commit.id)
  assert actual == Some("newer-head")
  assert runtime.history(subject, 1000) == []
  assert count(provider_calls) == 0

  // The pending candidate prevents another prompt from replacing it.
  let assert Error(run_error.Runtime(reason)) =
    runtime.run(subject, "second", 5000)
  assert string.contains(reason, "pending")
  assert runtime.history(subject, 1000) == []

  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
  stop_counter(provider_calls)
}

/// A pending retry that reports another head keeps the original commit pending.
pub fn session_pending_retry_with_different_head_stays_pending_test() {
  let commits = process.new_subject()
  let control = start_store_control([False, True])
  let provider_calls = start_counter()
  let provider_fn = fn(_request: provider.InferenceRequest) {
    process.send(provider_calls, Increment)
    Ok(provider.from_message(message.Assistant("unexpected", [], None, None)))
  }
  let #(subject, disp) =
    start_with_session_store(
      provider_fn,
      [],
      foreign_head_controlled_store(control, commits, "newer-head"),
      None,
    )

  let assert Error(run_error.Session(session_store.Unavailable("offline"))) =
    runtime.run(subject, "first", 5000)
  let assert Ok(first) = process.receive(commits, 1000)

  let assert Error(run_error.Session(session_store.ParentConflict(
    expected:,
    actual:,
  ))) = runtime.run_continue(subject, 5000)
  let assert Ok(retried) = process.receive(commits, 1000)
  assert retried == first
  assert expected == Some(first.id)
  assert actual == Some("newer-head")
  assert runtime.history(subject, 1000) == []
  assert count(provider_calls) == 0

  let assert Error(run_error.Runtime(reason)) =
    runtime.run(subject, "second", 5000)
  assert string.contains(reason, "pending")
  assert runtime.history(subject, 1000) == []

  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
  stop_counter(provider_calls)
}

/// An ambiguous failed commit remains pending and is retried with its exact ID.
pub fn session_pending_commit_retries_exactly_and_resumes_test() {
  let commits = process.new_subject()
  let control = start_store_control([False, True, True])
  let provider_calls = start_counter()
  let final = message.Assistant("retried", [], None, None)
  let provider_fn = fn(_request: provider.InferenceRequest) {
    process.send(provider_calls, Increment)
    Ok(provider.from_message(final))
  }
  let #(subject, disp) =
    start_with_session_store(
      provider_fn,
      [],
      controlled_store(control, commits),
      None,
    )

  // The user transition is ambiguous: it may have reached the store.
  let assert Error(run_error.Session(session_store.Unavailable("offline"))) =
    runtime.run(subject, "first", 5000)
  let assert Ok(first) = process.receive(commits, 1000)
  assert runtime.history(subject, 1000) == []
  assert count(provider_calls) == 0

  // Retry that exact commit, then commit the terminal assistant transition.
  let assert Ok(result) = runtime.run_continue(subject, 5000)
  assert result == final
  let assert Ok(retried) = process.receive(commits, 1000)
  let assert Ok(assistant_commit) = process.receive(commits, 1000)
  assert retried == first
  assert assistant_commit.parent == Some(first.id)
  assert count(provider_calls) == 1
  assert runtime.history(subject, 1000) == [message.User("first"), final]

  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

/// Failed retries remain pending, and a new prompt cannot replace pending work.
pub fn session_pending_commit_repeated_failure_rejects_new_prompt_test() {
  let commits = process.new_subject()
  let control = start_store_control([False, False])
  let provider_calls = start_counter()
  let provider_fn = fn(_request: provider.InferenceRequest) {
    process.send(provider_calls, Increment)
    Ok(provider.from_message(message.Assistant("unexpected", [], None, None)))
  }
  let #(subject, disp) =
    start_with_session_store(
      provider_fn,
      [],
      controlled_store(control, commits),
      None,
    )
  let assert Error(run_error.Session(session_store.Unavailable("offline"))) =
    runtime.run(subject, "first", 5000)
  let assert Ok(first) = process.receive(commits, 1000)

  let assert Error(run_error.Session(session_store.Unavailable("offline"))) =
    runtime.run_continue(subject, 5000)
  let assert Ok(retried) = process.receive(commits, 1000)
  assert retried == first
  assert runtime.history(subject, 1000) == []

  let assert Error(run_error.Runtime(message)) =
    runtime.run(subject, "second", 5000)
  assert string.contains(message, "pending")
  assert runtime.history(subject, 1000) == []
  assert count(provider_calls) == 0

  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

/// A rejected assistant commit retains the already durable user transition only.
pub fn session_assistant_commit_failure_retains_user_history_test() {
  let store =
    session_store.SessionStore(
      load: fn() { Ok(session_store.Session(None, [], None)) },
      commit: fn(commit) {
        case messages_in_commit(commit) {
          [message.Assistant(..)] -> Error(session_store.Unavailable("offline"))
          _ ->
            Ok(session_store.Session(
              Some(commit.id),
              messages_in_commit(commit),
              None,
            ))
        }
      },
    )
  let #(subject, disp) =
    start_with_session_store(
      fixed_provider(message.Assistant("hello", [], None, None)),
      [],
      store,
      None,
    )

  let assert Error(run_error.Session(session_store.Unavailable("offline"))) =
    runtime.run(subject, "hi", 5000)
  assert runtime.history(subject, 1000) == [message.User("hi")]

  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

/// A rejected assistant tool request remains uncommitted, so its tools never start.
pub fn session_assistant_tool_request_commit_failure_prevents_tool_start_test() {
  let provider_calls = start_counter()
  let tool_starts = start_counter()
  let tool_call =
    message.ToolCall(
      id: "echo-1",
      name: "echo",
      arguments_json: "{\"msg\":\"hello\"}",
    )
  let tool_request = message.Assistant("", [tool_call], None, None)
  let store =
    session_store.SessionStore(
      load: fn() { Ok(session_store.Session(None, [], None)) },
      commit: fn(commit) {
        case messages_in_commit(commit) {
          [message.Assistant(..)] -> Error(session_store.Unavailable("offline"))
          _ ->
            Ok(session_store.Session(
              Some(commit.id),
              messages_in_commit(commit),
              None,
            ))
        }
      },
    )
  let provider_fn = fn(_request: provider.InferenceRequest) {
    process.send(provider_calls, Increment)
    Ok(provider.from_message(tool_request))
  }
  let #(subject, disp) =
    start_with_session_store(
      provider_fn,
      [counted_echo_tool(tool_starts)],
      store,
      None,
    )

  let assert Error(run_error.Session(session_store.Unavailable("offline"))) =
    runtime.run(subject, "use echo", 5000)
  assert runtime.history(subject, 1000) == [message.User("use echo")]
  assert count(provider_calls) == 1
  assert count(tool_starts) == 0

  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
  stop_counter(provider_calls)
  stop_counter(tool_starts)
}

fn assert_session_commit_error_prevents_provider(
  commit_error: session_store.SessionError,
) -> Nil {
  let provider_calls = start_counter()
  let store =
    session_store.SessionStore(
      load: fn() { Ok(session_store.Session(None, [], None)) },
      commit: fn(_) { Error(commit_error) },
    )
  let provider_fn = fn(_request: provider.InferenceRequest) {
    process.send(provider_calls, Increment)
    Ok(provider.from_message(message.Assistant("unexpected", [], None, None)))
  }
  let #(subject, disp) = start_with_session_store(provider_fn, [], store, None)

  let assert Error(run_error.Session(actual_error)) =
    runtime.run(subject, "hi", 5000)
  assert actual_error == commit_error
  assert runtime.history(subject, 1000) == []
  assert count(provider_calls) == 0

  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
  stop_counter(provider_calls)
}

/// Store conflict and corruption errors retain their typed identity and stop inference.
pub fn session_parent_conflict_and_corrupt_commit_errors_prevent_inference_test() {
  assert_session_commit_error_prevents_provider(session_store.ParentConflict(
    expected: None,
    actual: Some("other-head"),
  ))
  assert_session_commit_error_prevents_provider(session_store.Corrupt(
    "commit log damaged",
  ))
}

/// A rejected complete tool batch retains the durable assistant tool request and
/// prevents another inference.
pub fn session_tool_batch_commit_failure_retains_assistant_history_test() {
  let provider_calls = start_counter()
  let first =
    message.ToolCall(id: "one", name: "echo", arguments_json: "{\"msg\":\"a\"}")
  let second =
    message.ToolCall(id: "two", name: "echo", arguments_json: "{\"msg\":\"b\"}")
  let tool_request = message.Assistant("", [first, second], None, None)
  let store =
    session_store.SessionStore(
      load: fn() { Ok(session_store.Session(None, [], None)) },
      commit: fn(commit) {
        case messages_in_commit(commit) {
          [message.Tool(..), message.Tool(..)] ->
            Error(session_store.Unavailable("offline"))
          _ ->
            Ok(session_store.Session(
              Some(commit.id),
              messages_in_commit(commit),
              None,
            ))
        }
      },
    )
  let provider_fn = fn(_request: provider.InferenceRequest) {
    process.send(provider_calls, Increment)
    Ok(provider.from_message(tool_request))
  }
  let #(subject, disp) =
    start_with_session_store(provider_fn, [echo_tool()], store, None)

  let assert Error(run_error.Session(session_store.Unavailable("offline"))) =
    runtime.run(subject, "run both", 5000)
  assert count(provider_calls) == 1
  assert runtime.history(subject, 1000)
    == [message.User("run both"), tool_request]

  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

/// Parallel tool results are checkpointed together as the complete tool delta.
pub fn session_two_tool_results_commit_as_one_delta_test() {
  let commits = process.new_subject()
  let commit_count = start_counter()
  let store =
    session_store.SessionStore(
      load: fn() { Ok(session_store.Session(None, [], None)) },
      commit: fn(commit) {
        process.send(commits, commit)
        process.send(commit_count, Increment)
        Ok(session_store.Session(
          Some(commit.id),
          messages_in_commit(commit),
          None,
        ))
      },
    )
  let first =
    message.ToolCall(id: "one", name: "echo", arguments_json: "{\"msg\":\"a\"}")
  let second =
    message.ToolCall(id: "two", name: "echo", arguments_json: "{\"msg\":\"b\"}")
  let tool_request = message.Assistant("", [first, second], None, None)
  let final = message.Assistant("done", [], None, None)
  let #(subject, disp) =
    start_with_session_store(
      sequenced_provider([tool_request, final]),
      [echo_tool()],
      store,
      None,
    )

  let assert Ok(result) = runtime.run(subject, "run both", 5000)
  assert result == final
  let assert Ok(_) = process.receive(commits, 1000)
  let assert Ok(_) = process.receive(commits, 1000)
  let assert Ok(tool_commit) = process.receive(commits, 1000)
  let assert Ok(_) = process.receive(commits, 1000)
  assert messages_in_commit(tool_commit)
    == [
      message.Tool(tool_call_id: "one", content: "{\"echo\":\"a\"}"),
      message.Tool(tool_call_id: "two", content: "{\"echo\":\"b\"}"),
    ]
  assert count(commit_count) == 4

  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

// ── Crash recovery after a successful durable commit ──────────────

type CrashBoundary {
  AfterUserCommit
  AfterToolRequestCommit
  AfterToolBatchCommit
  AfterTerminalAssistantCommit
}

/// Delegates the target commit to memory, confirms it is durable, then blocks
/// before returning to model a crash in the commit-success window.
fn crash_after_durable_commit_store(
  handle: memory.MemoryStore,
  persisted: process.Subject(session_store.SessionCommit),
  boundary: CrashBoundary,
) -> session_store.SessionStore {
  let durable = memory.store(handle)
  let blocker: process.Subject(Nil) = process.new_subject()
  let session_store.SessionStore(load:, commit:) = durable
  session_store.SessionStore(load:, commit: fn(next) {
    case commit(next) {
      Ok(_) as result ->
        case is_crash_boundary(boundary, next) {
          True -> {
            process.send(persisted, next)
            process.receive_forever(blocker)
            panic as "crashed commit resumed"
          }
          False -> result
        }
      Error(_) as result -> result
    }
  })
}

fn is_crash_boundary(
  boundary: CrashBoundary,
  commit: session_store.SessionCommit,
) -> Bool {
  let session_store.SessionCommit(delta:, ..) = commit
  let assert session_store.MessagesAppended(messages) = delta
  case boundary, messages {
    AfterUserCommit, [message.User(_)] -> True
    AfterToolRequestCommit, [message.Assistant(tool_calls: [_, ..], ..)] -> True
    AfterToolBatchCommit, [message.Tool(..), message.Tool(..)] -> True
    AfterTerminalAssistantCommit, [message.Assistant(tool_calls: [], ..)] ->
      True
    _, _ -> False
  }
}

fn counted_provider(
  counter: process.Subject(CounterMessage),
  provider_fn: provider.Provider,
) -> provider.Provider {
  fn(request: provider.InferenceRequest) {
    process.send(counter, Increment)
    provider_fn(request)
  }
}

fn counted_echo_tool(counter: process.Subject(CounterMessage)) -> tool.Tool {
  let base = echo_tool()
  tool.Tool(definition: base.definition, handler: fn(context, args) {
    process.send(counter, Increment)
    base.handler(context, args)
  })
}

fn start_restored_session(
  provider_fn: provider.Provider,
  tools: List(tool.Tool),
  store: session_store.SessionStore,
  snapshot: session_store.Session,
) -> #(
  process.Subject(runtime.RuntimeMsg),
  process.Subject(dispatcher.DispatcherMessage),
) {
  let session_store.Session(head:, messages:, inference_settings: _) = snapshot
  let assert Ok(disp) = dispatcher.start()
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let agent_config =
    state.config(provider_fn)
    |> state.with_tools(registry)
    |> state.with_model("test-model")
    |> state.with_max_iterations(50)
  let agent_state =
    list.fold(messages, state.new(agent_config), state.add_message)
  let config =
    runtime.RuntimeConfig(
      provider: provider_fn,
      tools: registry,
      hooks: [],
      dispatcher: disp,
      model: "test-model",
      max_iterations: 50,
      inference_settings: agent_config.inference_settings,
    )
  let initial_state =
    runtime.RuntimeState(
      agent_state:,
      config:,
      session: runtime.SessionReady(store, head),
      inference_settings: agent_config.inference_settings,
    )
  let assert Ok(subject) = runtime.start_with_state(config, initial_state)
  #(subject, disp)
}

/// Exercises every commit/effect boundary via the public replacement contract.
fn check_crash_after_successful_commit(boundary: CrashBoundary) {
  let provider_calls_before = start_counter()
  let provider_calls_after = start_counter()
  let tool_calls = start_counter()
  let first_call =
    message.ToolCall(
      id: "echo-1",
      name: "echo",
      arguments_json: "{\"msg\":\"restored one\"}",
    )
  let second_call =
    message.ToolCall(
      id: "echo-2",
      name: "echo",
      arguments_json: "{\"msg\":\"restored two\"}",
    )
  let tool_request =
    message.Assistant("", [first_call, second_call], None, None)
  let final = message.Assistant("complete", [], None, None)
  let original_delegate = case boundary {
    AfterToolRequestCommit | AfterToolBatchCommit ->
      sequenced_provider([tool_request, final])
    AfterUserCommit | AfterTerminalAssistantCommit -> fixed_provider(final)
  }
  let restored_delegate = case boundary {
    AfterToolRequestCommit | AfterToolBatchCommit ->
      sequenced_provider([tool_request, final])
    AfterUserCommit | AfterTerminalAssistantCommit -> fixed_provider(final)
  }
  let assert Ok(handle) = memory.start(session_store.Session(None, [], None))
  let persisted = process.new_subject()
  let store = crash_after_durable_commit_store(handle, persisted, boundary)
  let #(runtime_subject, dispatcher_before) =
    start_with_session_store(
      counted_provider(provider_calls_before, original_delegate),
      [counted_echo_tool(tool_calls)],
      store,
      None,
    )
  let assert Ok(runtime_pid) = process.subject_owner(runtime_subject)
  let runtime_monitor = process.monitor(runtime_pid)
  let caller =
    process.spawn_unlinked(fn() {
      let _ = runtime.try_run(runtime_subject, "restore this", 60_000)
      Nil
    })
  let caller_monitor = process.monitor(caller)

  let assert Ok(commit) = process.receive(persisted, 1000)
  assert is_crash_boundary(boundary, commit)
  process.unlink(runtime_pid)
  process.kill(runtime_pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(runtime_monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 1000)
  let caller_selector =
    process.new_selector()
    |> process.select_specific_monitor(caller_monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(caller_selector, 1000)

  let snapshot = memory.snapshot(handle)
  let assert session_store.Session(
    head: Some(_),
    messages: snapshot_history,
    inference_settings: _,
  ) = snapshot
  let expected_history = case boundary {
    AfterUserCommit -> [message.User("restore this")]
    AfterToolRequestCommit -> [message.User("restore this"), tool_request]
    AfterToolBatchCommit -> [
      message.User("restore this"),
      tool_request,
      message.Tool(
        tool_call_id: "echo-1",
        content: "{\"echo\":\"restored one\"}",
      ),
      message.Tool(
        tool_call_id: "echo-2",
        content: "{\"echo\":\"restored two\"}",
      ),
    ]
    AfterTerminalAssistantCommit -> [message.User("restore this"), final]
  }
  assert snapshot_history == expected_history

  let #(replacement, dispatcher_after) =
    start_restored_session(
      counted_provider(provider_calls_after, restored_delegate),
      [counted_echo_tool(tool_calls)],
      memory.store(handle),
      snapshot,
    )
  let assert Ok(result) = runtime.run_continue(replacement, 5000)
  assert result == final
  assert count(provider_calls_before)
    == case boundary {
      AfterUserCommit -> 0
      _ -> 1
    }
  assert count(provider_calls_after)
    == case boundary {
      AfterTerminalAssistantCommit -> 0
      _ -> 1
    }
  assert count(tool_calls)
    == case boundary {
      AfterToolRequestCommit | AfterToolBatchCommit -> 2
      _ -> 0
    }

  runtime.stop(replacement)
  process.send(dispatcher_after, dispatcher.Stop)
  process.send(dispatcher_before, dispatcher.Stop)
  memory.stop(handle)
  stop_counter(provider_calls_before)
  stop_counter(provider_calls_after)
  stop_counter(tool_calls)
}

/// A durable user prompt resumes at the provider without replaying prior work.
pub fn crash_after_user_commit_restores_provider_action_test() {
  check_crash_after_successful_commit(AfterUserCommit)
}

/// A durable assistant tool request resumes by executing its pending tools.
pub fn crash_after_tool_request_commit_restores_tool_action_test() {
  check_crash_after_successful_commit(AfterToolRequestCommit)
}

/// A durable complete tool batch resumes at the next provider call only.
pub fn crash_after_tool_batch_commit_restores_provider_action_test() {
  check_crash_after_successful_commit(AfterToolBatchCommit)
}

/// A durable terminal assistant is returned without another provider call.
pub fn crash_after_terminal_assistant_commit_returns_durably_test() {
  check_crash_after_successful_commit(AfterTerminalAssistantCommit)
}

// ══════════════════════════════════════════════════════════════════
//  run_continue — Durable Agent Loop
// ══════════════════════════════════════════════════════════════════

/// Start a runtime with pre-loaded history for run_continue tests.
fn start_with_history(
  provider_fn: provider.Provider,
  tools: List(tool.Tool),
  history: List(message.Message),
) -> #(
  process.Subject(runtime.RuntimeMsg),
  process.Subject(dispatcher.DispatcherMessage),
) {
  let assert Ok(disp) = dispatcher.start()
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let agent_config =
    state.config(provider_fn)
    |> state.with_tools(registry)
    |> state.with_model("test-model")
    |> state.with_max_iterations(50)
  let agent_st = list.fold(history, state.new(agent_config), state.add_message)
  let runtime_config =
    runtime.RuntimeConfig(
      provider: provider_fn,
      tools: registry,
      hooks: [],
      dispatcher: disp,
      model: "test-model",
      max_iterations: 50,
      inference_settings: agent_config.inference_settings,
    )
  let rt_state =
    runtime.RuntimeState(
      agent_state: agent_st,
      config: runtime_config,
      session: runtime.SessionDisabled,
      inference_settings: agent_config.inference_settings,
    )
  let assert Ok(subject) = runtime.start_with_state(runtime_config, rt_state)
  #(subject, disp)
}

/// run_continue with empty history returns error.
pub fn run_continue_empty_history_returns_error_test() {
  let #(subject, disp) =
    start_with_history(
      fixed_provider(message.Assistant("hi", [], None, None)),
      [],
      [],
    )
  let assert Error(run_error.Runtime(message)) =
    runtime.run_continue(subject, 5000)
  assert string.contains(message, "no history to continue")
  process.send(disp, dispatcher.Stop)
}

/// run_continue with history ending in completed assistant returns it immediately.
pub fn run_continue_completed_assistant_returns_immediately_test() {
  let completed = message.Assistant("done", [], None, Some(stop_reason.Stop))
  let #(subject, disp) =
    start_with_history(
      fn(_request: provider.InferenceRequest) {
        Error(error.ApiError("should not be called"))
      },
      [],
      [message.User("hi"), completed],
    )
  let assert Ok(msg) = runtime.run_continue(subject, 5000)
  assert msg == completed
  process.send(disp, dispatcher.Stop)
}

/// run_continue with history ending in assistant with no stop_reason (legacy)
/// treats it as done.
pub fn run_continue_legacy_assistant_returns_immediately_test() {
  let completed = message.Assistant("legacy done", [], None, None)
  let #(subject, disp) =
    start_with_history(
      fn(_request: provider.InferenceRequest) {
        Error(error.ApiError("should not be called"))
      },
      [],
      [message.User("hi"), completed],
    )
  let assert Ok(msg) = runtime.run_continue(subject, 5000)
  assert msg == completed
  process.send(disp, dispatcher.Stop)
}

/// run_continue with history ending in user message calls provider.
pub fn run_continue_user_message_calls_provider_test() {
  let final = message.Assistant("response", [], None, None)
  let #(subject, disp) =
    start_with_history(fixed_provider(final), [], [
      message.User("resume from here"),
    ])
  let assert Ok(msg) = runtime.run_continue(subject, 5000)
  assert msg == final
  process.send(disp, dispatcher.Stop)
}

/// run_continue with history ending in tool message calls provider.
pub fn run_continue_tool_message_calls_provider_test() {
  let final = message.Assistant("after tool", [], None, None)
  let tc =
    message.ToolCall(id: "c1", name: "echo", arguments_json: "{\"msg\":\"x\"}")
  let #(subject, disp) =
    start_with_history(fixed_provider(final), [echo_tool()], [
      message.User("go"),
      message.Assistant("", [tc], None, None),
      message.Tool(tool_call_id: "c1", content: "result"),
    ])
  let assert Ok(msg) = runtime.run_continue(subject, 5000)
  assert msg == final
  process.send(disp, dispatcher.Stop)
}

/// run_continue with history ending in assistant with pending tool calls
/// executes the tools and continues the loop.
pub fn run_continue_pending_tool_calls_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"hello\"}",
    )
  let tool_resp = message.Assistant("", [tc], None, Some(stop_reason.ToolUse))
  let final = message.Assistant("tool done!", [], None, None)
  let #(subject, disp) =
    start_with_history(
      // sequenced_provider counts assistant messages in messages sent to provider.
      // History already has 1 assistant, so next call will be at index 1.
      // tool_resp at index 0 is unused padding for index alignment.
      sequenced_provider([tool_resp, final]),
      [echo_tool()],
      [message.User("use echo"), tool_resp],
    )
  let assert Ok(msg) = runtime.run_continue(subject, 5000)
  assert msg == final
  process.send(disp, dispatcher.Stop)
}

/// Pending calls restored from history retain their original identity in context.
pub fn run_continue_pending_tool_call_preserves_context_test() {
  let call =
    message.ToolCall(id: "persisted-id", name: "context", arguments_json: "{}")
  let pending = message.Assistant("", [call], None, Some(stop_reason.ToolUse))
  let final = message.Assistant("done", [], None, None)
  let #(subject, disp) =
    start_with_history(sequenced_provider([pending, final]), [context_tool()], [
      message.User("resume"),
      pending,
    ])
  let assert Ok(_) = runtime.run_continue(subject, 5000)
  let messages = runtime.history(subject, 5000)
  assert list.contains(
    messages,
    message.Tool(
      tool_call_id: "persisted-id",
      content: "{\"id\":\"persisted-id\",\"name\":\"context\"}",
    ),
  )
  process.send(disp, dispatcher.Stop)
}

/// Pending calls restored from a durable session retain their exact context.
pub fn restored_history_pending_tool_call_preserves_context_test() {
  let call =
    message.ToolCall(id: "restored-id", name: "context", arguments_json: "{}")
  let pending = message.Assistant("", [call], None, Some(stop_reason.ToolUse))
  let final = message.Assistant("done", [], None, None)
  let snapshot =
    session_store.Session(
      Some("restored-head"),
      [message.User("resume"), pending],
      None,
    )
  let assert Ok(store_handle) = memory.start(snapshot)
  let #(subject, disp) =
    start_restored_session(
      sequenced_provider([pending, final]),
      [context_tool()],
      memory.store(store_handle),
      snapshot,
    )
  let assert Ok(_) = runtime.run_continue(subject, 5000)
  assert list.contains(
    runtime.history(subject, 5000),
    message.Tool(
      tool_call_id: "restored-id",
      content: "{\"id\":\"restored-id\",\"name\":\"context\"}",
    ),
  )
  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
  memory.stop(store_handle)
}

/// run_continue with length stop_reason re-calls provider.
pub fn run_continue_length_stop_reason_recalls_provider_test() {
  let truncated =
    message.Assistant("truncated...", [], None, Some(stop_reason.Length))
  let final = message.Assistant("full response", [], None, None)
  let #(subject, disp) =
    start_with_history(fixed_provider(final), [], [
      message.User("tell me a story"),
      truncated,
    ])
  let assert Ok(msg) = runtime.run_continue(subject, 5000)
  assert msg == final
  process.send(disp, dispatcher.Stop)
}

/// try_run_continue preserves the runtime's successful response.
pub fn try_run_continue_returns_message_test() {
  let final = message.Assistant("continued", [], None, None)
  let #(subject, disp) =
    start_with_history(fixed_provider(final), [], [message.User("resume")])
  let assert Ok(Ok(msg)) = runtime.try_run_continue(subject, 5000)
  assert msg == final
  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

/// try_run_continue returns Error(Nil) when a continuation times out.
pub fn try_run_continue_timeout_returns_error_test() {
  let blocked_provider = fn(_request: provider.InferenceRequest) {
    process.sleep_forever()
    panic as "blocked provider resumed"
  }
  let #(subject, disp) =
    start_with_history(blocked_provider, [], [message.User("resume")])
  let assert Ok(pid) = process.subject_owner(subject)

  let assert Error(Nil) = runtime.try_run_continue(subject, 50)
  assert process.is_alive(pid)

  process.unlink(pid)
  process.kill(pid)
  process.send(disp, dispatcher.Stop)
}

/// A low-level RuntimeConfig carries its configured settings into provider calls.
pub fn low_level_runtime_config_settings_are_used_test() {
  let settings = provider.with_thinking_level(thinking.High)
  let seen = process.new_subject()
  let response = message.Assistant("configured", [], None, None)
  let provider_fn = fn(request: provider.InferenceRequest) {
    process.send(seen, request.settings)
    Ok(provider.from_message(response))
  }
  let assert Ok(disp) = dispatcher.start()
  let config =
    runtime.RuntimeConfig(
      provider: provider_fn,
      tools: tool.new_registry(),
      hooks: [],
      dispatcher: disp,
      model: "test-model",
      max_iterations: 50,
      inference_settings: settings,
    )
  let assert Ok(subject) = runtime.start(config)
  let assert Ok(_) = runtime.run(subject, "hello", 5000)
  let assert Ok(actual) = process.receive(seen, 1000)
  assert actual == settings
  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

/// A non-durable settings setter changes subsequent provider requests.
pub fn non_durable_settings_setter_is_applied_test() {
  let settings = provider.with_thinking_level(thinking.Medium)
  let seen = process.new_subject()
  let response = message.Assistant("updated", [], None, None)
  let provider_fn = fn(request: provider.InferenceRequest) {
    process.send(seen, request.settings)
    Ok(provider.from_message(response))
  }
  let #(subject, disp) = start_simple(provider_fn, [])
  let assert Ok(Nil) = runtime.set_inference_settings(subject, settings, 5000)
  let assert Ok(_) = runtime.run(subject, "hello", 5000)
  let assert Ok(actual) = process.receive(seen, 1000)
  assert actual == settings
  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

/// Settings remain unchanged while a provider call executes tools and resumes.
pub fn settings_stay_stable_across_provider_tool_provider_loop_test() {
  let settings = provider.with_thinking_level(thinking.High)
  let seen = process.new_subject()
  let tool_call =
    message.ToolCall(
      id: "settings-tool",
      name: "echo",
      arguments_json: "{\"msg\":\"ok\"}",
    )
  let tool_response = message.Assistant("", [tool_call], None, None)
  let final = message.Assistant("finished", [], None, None)
  let provider_fn = fn(request: provider.InferenceRequest) {
    process.send(seen, request.settings)
    let assistant_count =
      request.messages
      |> list.filter(fn(msg) {
        case msg {
          message.Assistant(..) -> True
          _ -> False
        }
      })
      |> list.length()
    case assistant_count {
      0 -> Ok(provider.from_message(tool_response))
      _ -> Ok(provider.from_message(final))
    }
  }
  let #(subject, disp) = start_simple(provider_fn, [echo_tool()])
  let assert Ok(Nil) = runtime.set_inference_settings(subject, settings, 5000)
  let assert Ok(result) = runtime.run(subject, "use the tool", 5000)
  assert result == final
  let assert Ok(first) = process.receive(seen, 1000)
  let assert Ok(second) = process.receive(seen, 1000)
  assert first == settings
  assert second == settings
  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

/// A durable settings setter persists the setting in the session store.
pub fn durable_settings_setter_succeeds_and_persists_test() {
  let settings = provider.with_thinking_level(thinking.Medium)
  let assert Ok(store_handle) =
    memory.start(session_store.Session(None, [], None))
  let store = memory.store(store_handle)
  let #(subject, disp) =
    start_with_session_store(
      fixed_provider(message.Assistant("ok", [], None, None)),
      [],
      store,
      None,
    )
  let assert Ok(Nil) = runtime.set_inference_settings(subject, settings, 5000)
  let snapshot = memory.snapshot(store_handle)
  assert snapshot.inference_settings == Some(settings)
  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
  memory.stop(store_handle)
}

/// An ambiguous durable settings commit is retried exactly, while another
/// setting is rejected until the original commit is resolved.
pub fn durable_settings_failure_exact_retry_and_different_rejection_test() {
  let settings = provider.with_thinking_level(thinking.Medium)
  let different = provider.with_thinking_level(thinking.High)
  let commits = process.new_subject()
  let control = start_store_control([False, True])
  let store = controlled_store(control, commits)
  let #(subject, disp) =
    start_with_session_store(
      fixed_provider(message.Assistant("ok", [], None, None)),
      [],
      store,
      None,
    )
  let assert Error(run_error.Session(session_store.Unavailable("offline"))) =
    runtime.set_inference_settings(subject, settings, 5000)
  let assert Ok(first) = process.receive(commits, 1000)
  let assert Error(run_error.Runtime(reason)) =
    runtime.set_inference_settings(subject, different, 5000)
  assert string.contains(reason, "different")
  let assert Ok(Nil) = runtime.set_inference_settings(subject, settings, 5000)
  let assert Ok(retried) = process.receive(commits, 1000)
  assert retried == first
  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

fn assert_settings_error_is_non_pending(
  error: session_store.SessionError,
) -> Nil {
  let commits = process.new_subject()
  let failures = start_settings_failure_control([error])
  let store = settings_failure_store(failures, commits)
  let #(subject, disp) =
    start_with_session_store(
      fixed_provider(message.Assistant("ok", [], None, None)),
      [],
      store,
      Some("old-head"),
    )
  let assert Error(run_error.Session(actual)) =
    runtime.set_inference_settings(
      subject,
      provider.with_thinking_level(thinking.Medium),
      5000,
    )
  assert actual == error

  let assert Ok(_) = runtime.run(subject, "future run", 5000)
  let assert Ok(message_commit) = process.receive(commits, 1000)
  assert message_commit.parent == Some("old-head")
  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

pub fn invalid_settings_commit_does_not_block_future_runs_test() {
  assert_settings_error_is_non_pending(session_store.InvalidCommit(
    "bad settings",
  ))
}

pub fn corrupt_settings_commit_does_not_block_future_runs_test() {
  assert_settings_error_is_non_pending(session_store.Corrupt("damaged settings"))
}

fn assert_settings_retry_error_is_non_pending(
  error: session_store.SessionError,
) -> Nil {
  let commits = process.new_subject()
  let failures =
    start_settings_failure_control([
      session_store.Unavailable("offline"),
      error,
    ])
  let store = settings_failure_store(failures, commits)
  let #(subject, disp) =
    start_with_session_store(
      fixed_provider(message.Assistant("ok", [], None, None)),
      [],
      store,
      Some("old-head"),
    )
  let settings = provider.with_thinking_level(thinking.Medium)
  let assert Error(run_error.Session(session_store.Unavailable("offline"))) =
    runtime.set_inference_settings(subject, settings, 5000)
  let assert Ok(first) = process.receive(commits, 1000)

  let assert Error(run_error.Session(actual)) =
    runtime.set_inference_settings(subject, settings, 5000)
  assert actual == error
  let assert Ok(retried) = process.receive(commits, 1000)
  assert retried == first

  let assert Ok(_) = runtime.run(subject, "future run", 5000)
  let assert Ok(message_commit) = process.receive(commits, 1000)
  assert message_commit.parent == Some("old-head")
  runtime.stop(subject)
  process.send(disp, dispatcher.Stop)
}

pub fn invalid_settings_retry_does_not_remain_pending_test() {
  assert_settings_retry_error_is_non_pending(session_store.InvalidCommit(
    "bad settings",
  ))
}

pub fn corrupt_settings_retry_does_not_remain_pending_test() {
  assert_settings_retry_error_is_non_pending(session_store.Corrupt(
    "damaged settings",
  ))
}
