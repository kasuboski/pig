//// Hooks integration tests — hooks wired through the core agent loop.
////
//// Tests verify that hooks fire at the right lifecycle points,
//// decisions are respected, and observability events are emitted.
//// Uses providers that inspect their input messages to verify hook effects.

import gleeunit
import gleeunit/should
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import pig/agent/actor
import pig/agent/core
import pig/agent/state
import pig/ai/error
import pig/ai/message
import pig/ai/provider
import pig/hooks
import pig/obs/dispatcher
import pig/obs/session as session_writer
import pig/tool
import simplifile
import support/harness
import temporary

pub fn main() {
  gleeunit.main()
}

// ── Tool Call Decision Tests ─────────────────────────────────────────

/// When a hook blocks a tool, the LLM receives a Tool message with
/// "Tool blocked by '<name>': <reason>" instead of the tool result.
/// The provider (LLM) can then adapt.
pub fn hook_blocks_tool_sends_error_to_provider_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"hello\"}",
    )
  // First response: ask for tool call. Second response: acknowledge blocked.
  let response1 = message.Assistant("", [tc], None)
  let response2 = message.Assistant("I see the tool was blocked", [], None)
  let guard =
    hooks.new("guard")
    |> hooks.on_tool_call(fn(event) {
      case event.tool_name == "echo" {
        True -> hooks.block_tool("echo not allowed")
        False -> hooks.allow_tool()
      }
    })

  // Provider that verifies it sees the blocked message
  let provider = fn(msgs, _tools) {
    case list.length(msgs) {
      // First call: just the user message
      1 -> Ok(provider.from_message(response1))
      // Second call: user + assistant + tool result/blocked message
      _ -> {
        // Verify the last message is a Tool message with "blocked" content
        let tool_msg = list.last(msgs) |> result.unwrap(message.User(""))
        case tool_msg {
          message.Tool(content:, ..) -> {
            case string.contains(content, "blocked") {
              True -> Ok(provider.from_message(response2))
              False ->
                Error(error.ApiError(
                  "Expected blocked tool message, got: " <> content,
                ))
            }
          }
          _ ->
            Error(error.ApiError(
              "Expected Tool message, got something else",
            ))
        }
      }
    }
  }

  let assert Ok(disp) = dispatcher.start()
  let registry = tool.new_registry() |> tool.register(harness.echo_tool())
  let cfg =
    state.config(provider)
    |> state.with_tools(registry)
    |> state.with_dispatcher(disp)
    |> state.with_hooks(guard)

  let st = state.new(cfg) |> state.add_message(message.User("use echo"))
  let result = core.run_to_completion(st)
  let assert Ok(final) = result
  should.equal(final, response2)
}

/// When no hooks block, tools execute normally.
pub fn hook_allows_tool_executes_normally_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"hello\"}",
    )
  let response1 = message.Assistant("", [tc], None)
  let response2 = message.Assistant("got it", [], None)
  let guard =
    hooks.new("guard")
    |> hooks.on_tool_call(fn(_) { hooks.allow_tool() })

  // Provider that verifies it sees the actual tool result (not blocked)
  let provider = fn(msgs, _tools) {
    case list.length(msgs) {
      1 -> Ok(provider.from_message(response1))
      _ -> {
        let tool_msg = list.last(msgs) |> result.unwrap(message.User(""))
        case tool_msg {
          message.Tool(content:, ..) -> {
            case string.contains(content, "blocked") {
              False -> Ok(provider.from_message(response2))
              True ->
                Error(error.ApiError(
                  "Tool was blocked but should have been allowed",
                ))
            }
          }
          _ ->
            Error(error.ApiError("Expected Tool message"))
        }
      }
    }
  }

  let assert Ok(disp) = dispatcher.start()
  let registry = tool.new_registry() |> tool.register(harness.echo_tool())
  let cfg =
    state.config(provider)
    |> state.with_tools(registry)
    |> state.with_dispatcher(disp)
    |> state.with_hooks(guard)

  let st = state.new(cfg) |> state.add_message(message.User("use echo"))
  let result = core.run_to_completion(st)
  let assert Ok(final) = result
  should.equal(final, response2)
}

/// When a hook transforms tool results, the provider sees the transformed content.
pub fn hook_transforms_tool_result_provider_sees_scrubbed_test() {
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

  // Provider that verifies it sees REDACTED content
  let provider = fn(msgs, _tools) {
    case list.length(msgs) {
      1 -> Ok(provider.from_message(response1))
      _ -> {
        let tool_msg = list.last(msgs) |> result.unwrap(message.User(""))
        case tool_msg {
          message.Tool(content:, ..) -> {
            case content == "[REDACTED]" {
              True -> Ok(provider.from_message(response2))
              False ->
                Error(error.ApiError(
                  "Expected [REDACTED], got: " <> content,
                ))
            }
          }
          _ ->
            Error(error.ApiError("Expected Tool message"))
        }
      }
    }
  }

  let assert Ok(disp) = dispatcher.start()
  let registry = tool.new_registry() |> tool.register(harness.echo_tool())
  let cfg =
    state.config(provider)
    |> state.with_tools(registry)
    |> state.with_dispatcher(disp)
    |> state.with_hooks(scrubber)

  let st = state.new(cfg) |> state.add_message(message.User("use echo"))
  let result = core.run_to_completion(st)
  let assert Ok(final) = result
  should.equal(final, response2)
}

/// No hooks at all — tools execute normally (baseline).
pub fn no_hooks_tools_execute_normally_test() {
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"hello\"}",
    )
  let response1 = message.Assistant("", [tc], None)
  let response2 = message.Assistant("done", [], None)

  let provider = harness.sequenced_provider_for_actor([response1, response2])
  let assert Ok(disp) = dispatcher.start()
  let registry = tool.new_registry() |> tool.register(harness.echo_tool())
  let cfg =
    state.config(provider)
    |> state.with_tools(registry)
    |> state.with_dispatcher(disp)

  let st = state.new(cfg) |> state.add_message(message.User("use echo"))
  let result = core.run_to_completion(st)
  let assert Ok(final) = result
  should.equal(final, response2)
}

// ── Actor-Level Integration Tests ────────────────────────────────────

/// Hook blocks a tool through the full actor pipeline.
/// Verifies the blocked tool message appears in the session writer output.
pub fn actor_hook_blocks_tool_and_session_writer_records_it_test() {
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

  let provider = harness.sequenced_provider_for_actor([response1, response2])

  use path <- with_temp_file("hook_blocked")
  let assert Ok(disp) = dispatcher.start()

  // Register session writer as consumer on dispatcher
  let assert Ok(consumer) = session_writer.start_consumer(path)
  process.send(disp, dispatcher.RegisterConsumer(consumer))

  let registry = tool.new_registry() |> tool.register(harness.echo_tool())
  let cfg =
    state.config(provider)
    |> state.with_tools(registry)
    |> state.with_dispatcher(disp)
    |> state.with_hooks(guard)
    |> state.with_session_path(path)

  let assert Ok(subject) = actor.start(cfg)
  let assert Ok(final) = actor.run(subject, "use echo", 5000)
  should.equal(final, response2)
  actor.stop(subject)

  // Give consumer time to write
  let _ = process.receive(process.new_subject(), 200)
  process.send(disp, dispatcher.Stop)

  // Read session file and verify tool_blocked event
  let assert Ok(content) = simplifile.read(path)
  let lines =
    content
    |> string.split("\n")
    |> list.filter(fn(l) { l != "" })

  // At least one line should be a tool_blocked event
  let has_blocked =
    list.any(lines, fn(line) {
      string.contains(line, "\"event\":\"tool_blocked\"")
        && string.contains(line, "\"hook_name\":\"guard\"")
        && string.contains(line, "\"reason\":\"echo blocked\"")
    })
  should.be_true(has_blocked)

  // Also verify HookActed event is emitted for the blocked tool
  let has_hook_acted =
    list.any(lines, fn(line) {
      string.contains(line, "\"event\":\"hook_acted\"")
        && string.contains(line, "\"hook_name\":\"guard\"")
        && string.contains(line, "\"hook_point\":\"before_tool_call\"")
    })
  should.be_true(has_hook_acted)
}

/// Actor accumulates history across multiple runs with hooks.
pub fn actor_hooks_accumulate_history_across_runs_test() {
  let ok = message.Assistant("ok", [], None)
  let count_subject = process.new_subject()
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
    process.send(count_subject, user_count)
    Ok(provider.from_message(ok))
  }

  let guard =
    hooks.new("noop")
    |> hooks.on_tool_call(fn(_) { hooks.allow_tool() })

  let assert Ok(disp) = dispatcher.start()
  let cfg =
    state.config(provider)
    |> state.with_dispatcher(disp)
    |> state.with_hooks(guard)

  let assert Ok(subject) = actor.start(cfg)
  let assert Ok(_) = actor.run(subject, "one", 5000)
  let assert Ok(1) = process.receive(count_subject, 1000)
  let assert Ok(_) = actor.run(subject, "two", 5000)
  // Second run should see both user messages (accumulated history)
  let assert Ok(2) = process.receive(count_subject, 1000)
  actor.stop(subject)
  process.send(disp, dispatcher.Stop)
}

// ── Test Helpers ──────────────────────────────────────────────────────

fn with_temp_file(
  name: String,
  run test_fn: fn(String) -> a,
) -> a {
  let tmp =
    temporary.file()
    |> temporary.with_prefix("pig_hook_" <> name <> "_")
    |> temporary.with_suffix(".jsonl")
  let assert Ok(result) = temporary.create(tmp, test_fn)
  result
}

// ── Message Decision (before_inference) Tests ─────────────────────────

/// Hook transforms messages before inference via decide_messages.
/// The provider sees the transformed messages (with prefix injected).
pub fn hook_transforms_messages_before_inference_test() {
  let ok = message.Assistant("ok", [], None)
  // Provider inspects the messages it receives
  let seen_subject = process.new_subject()
  let provider = fn(msgs, _tools) {
    // Send the first user message content for verification
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
      Ok(message.User(content)) -> process.send(seen_subject, content)
      _ -> Nil
    }
    Ok(provider.from_message(ok))
  }

  // Hook adds a prefix to user messages
  let scrubber =
    hooks.new("prefixer")
    |> hooks.on_before_inference(fn(event) {
      let transformed =
        event.messages
        |> list.map(fn(m) {
          case m {
            message.User(content) ->
              message.User("[scrubbed] " <> content)
            other -> other
          }
        })
      hooks.ReplaceMessages(transformed)
    })

  let assert Ok(disp) = dispatcher.start()
  let cfg =
    state.config(provider)
    |> state.with_dispatcher(disp)
    |> state.with_hooks(scrubber)

  let st = state.new(cfg) |> state.add_message(message.User("hello"))
  let result = core.step(st)
  let assert core.Complete(_) = result

  // Provider should have seen the prefixed message
  let assert Ok(content) = process.receive(seen_subject, 2000)
  should.equal(content, "[scrubbed] hello")

  process.send(disp, dispatcher.Stop)
}
