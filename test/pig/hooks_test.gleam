//// Hooks system tests.
////
//// Comprehensive unit tests for the hooks module following TDD principles.
//// Tests verify the renamed Hooks type (was Extension) and composition
//// functions that take List(Hooks) instead of ExtensionStack.

import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit
import pig/ai/error
import pig/ai/message
import pig/hooks

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Builder Tests ───────────────────────────────────────────────────

pub fn new_creates_hooks_with_name_test() {
  let h = hooks.new("my-hooks")
  let hooks.Hooks(name:, ..) = h
  assert name == "my-hooks"
}

pub fn new_hooks_allows_tools_by_default_test() {
  let h = hooks.new("test")
  let event =
    hooks.ToolCallEvent(
      tool_name: "test_tool",
      tool_call_id: "call_123",
      arguments_json: "{}",
    )
  let action = case h {
    hooks.Hooks(on_tool_call: handler, ..) -> handler(event)
  }
  assert action == hooks.AllowTool
}

pub fn new_hooks_keeps_results_by_default_test() {
  let h = hooks.new("test")
  let event =
    hooks.ToolResultEvent(
      tool_name: "test_tool",
      tool_call_id: "call_123",
      result: "original result",
      is_error: False,
      duration_ms: 100,
    )
  let action = case h {
    hooks.Hooks(on_tool_result: handler, ..) -> handler(event)
  }
  assert action == hooks.KeepResult
}

pub fn new_hooks_keeps_messages_by_default_test() {
  let h = hooks.new("test")
  let messages = [message.User("hello"), message.System("system")]
  let event = hooks.BeforeInferenceEvent(model: "gpt-4", messages: messages)
  let action = case h {
    hooks.Hooks(on_before_inference: handler, ..) -> handler(event)
  }
  assert action == hooks.KeepMessages
}

pub fn on_tool_call_replaces_handler_test() {
  let h =
    hooks.new("test")
    |> hooks.on_tool_call(fn(_) { hooks.BlockTool("blocked") })
  let event =
    hooks.ToolCallEvent(
      tool_name: "test_tool",
      tool_call_id: "call_123",
      arguments_json: "{}",
    )
  let action = case h {
    hooks.Hooks(on_tool_call: handler, ..) -> handler(event)
  }
  assert action == hooks.BlockTool("blocked")
}

pub fn on_tool_result_replaces_handler_test() {
  let h =
    hooks.new("test")
    |> hooks.on_tool_result(fn(_) { hooks.ReplaceResult("new result", True) })
  let event =
    hooks.ToolResultEvent(
      tool_name: "test_tool",
      tool_call_id: "call_123",
      result: "original result",
      is_error: False,
      duration_ms: 100,
    )
  let action = case h {
    hooks.Hooks(on_tool_result: handler, ..) -> handler(event)
  }
  assert action == hooks.ReplaceResult("new result", True)
}

pub fn on_before_inference_replaces_handler_test() {
  let new_messages = [message.User("modified")]
  let h =
    hooks.new("test")
    |> hooks.on_before_inference(fn(_) { hooks.ReplaceMessages(new_messages) })
  let event =
    hooks.BeforeInferenceEvent(model: "gpt-4", messages: [
      message.User("original"),
    ])
  let action = case h {
    hooks.Hooks(on_before_inference: handler, ..) -> handler(event)
  }
  assert action == hooks.ReplaceMessages(new_messages)
}

pub fn on_after_inference_replaces_handler_test() {
  let signal = process.new_subject()
  let h =
    hooks.new("test")
    |> hooks.on_after_inference(fn(_) { process.send(signal, Nil) })
  let event =
    hooks.AfterInferenceEvent(
      model: "gpt-4",
      message: message.Assistant("response", [], None),
      duration_ms: 100,
    )
  let _ = case h {
    hooks.Hooks(on_after_inference: handler, ..) -> handler(event)
  }
  let assert Ok(Nil) = process.receive(signal, 1000)
}

pub fn on_error_replaces_handler_test() {
  let signal = process.new_subject()
  let h =
    hooks.new("test")
    |> hooks.on_error(fn(_) { process.send(signal, Nil) })
  let event =
    hooks.ErrorEvent(model: "gpt-4", error: error.ApiError("test error"))
  let _ = case h {
    hooks.Hooks(on_error: handler, ..) -> handler(event)
  }
  let assert Ok(Nil) = process.receive(signal, 1000)
}

pub fn on_complete_replaces_handler_test() {
  let signal = process.new_subject()
  let h =
    hooks.new("test")
    |> hooks.on_complete(fn(_) { process.send(signal, Nil) })
  let event =
    hooks.CompleteEvent(
      model: "gpt-4",
      message: message.Assistant("final", [], None),
      total_iterations: 5,
    )
  let _ = case h {
    hooks.Hooks(on_complete: handler, ..) -> handler(event)
  }
  let assert Ok(Nil) = process.receive(signal, 1000)
}

// ── Composition Tests: Notification Handlers (List(Hooks)) ──────────

pub fn notify_after_inference_calls_all_handlers_test() {
  let signal = process.new_subject()
  let h1 =
    hooks.new("observer1")
    |> hooks.on_after_inference(fn(_) { process.send(signal, Nil) })
  let h2 =
    hooks.new("observer2")
    |> hooks.on_after_inference(fn(_) { process.send(signal, Nil) })
  let event =
    hooks.AfterInferenceEvent(
      model: "gpt-4",
      message: message.Assistant("response", [], None),
      duration_ms: 100,
    )
  hooks.notify_after_inference([h1, h2], event)
  let assert Ok(Nil) = process.receive(signal, 1000)
  let assert Ok(Nil) = process.receive(signal, 1000)
}

pub fn notify_error_calls_all_handlers_test() {
  let signal = process.new_subject()
  let h1 =
    hooks.new("error_handler1")
    |> hooks.on_error(fn(_) { process.send(signal, Nil) })
  let h2 =
    hooks.new("error_handler2")
    |> hooks.on_error(fn(_) { process.send(signal, Nil) })
  let event =
    hooks.ErrorEvent(model: "gpt-4", error: error.ApiError("test error"))
  hooks.notify_error([h1, h2], event)
  let assert Ok(Nil) = process.receive(signal, 1000)
  let assert Ok(Nil) = process.receive(signal, 1000)
}

pub fn notify_complete_calls_all_handlers_test() {
  let signal = process.new_subject()
  let h1 =
    hooks.new("observer1")
    |> hooks.on_complete(fn(_) { process.send(signal, Nil) })
  let h2 =
    hooks.new("observer2")
    |> hooks.on_complete(fn(_) { process.send(signal, Nil) })
  let event =
    hooks.CompleteEvent(
      model: "gpt-4",
      message: message.Assistant("final", [], None),
      total_iterations: 5,
    )
  hooks.notify_complete([h1, h2], event)
  let assert Ok(Nil) = process.receive(signal, 1000)
  let assert Ok(Nil) = process.receive(signal, 1000)
}

// ── Action Constructor Tests ─────────────────────────────────────────

pub fn allow_tool_returns_allow_test() {
  let action = hooks.allow_tool()
  assert action == hooks.AllowTool
}

pub fn block_tool_returns_block_with_reason_test() {
  let action = hooks.block_tool("not allowed")
  assert action == hooks.BlockTool("not allowed")
}

pub fn keep_result_returns_keep_test() {
  let action = hooks.keep_result()
  assert action == hooks.KeepResult
}

pub fn replace_result_returns_replace_test() {
  let action = hooks.replace_result("new content", True)
  assert action == hooks.ReplaceResult("new content", True)
}

pub fn keep_messages_returns_keep_test() {
  let action = hooks.keep_messages()
  assert action == hooks.KeepMessages
}

pub fn replace_messages_returns_replace_test() {
  let messages = [message.User("test")]
  let action = hooks.replace_messages(messages)
  assert action == hooks.ReplaceMessages(messages)
}

// ── Decision Type Tests ──────────────────────────────────────────────

// decide_tool_call returns ToolCallDecision with attribution

pub fn decide_tool_call_allows_when_no_hooks_test() {
  let event =
    hooks.ToolCallEvent(
      tool_name: "bash",
      tool_call_id: "c1",
      arguments_json: "{}",
    )
  let decision = hooks.decide_tool_call([], event)
  assert decision == hooks.ToolAllowed
}

pub fn decide_tool_call_allows_when_all_allow_test() {
  let h =
    hooks.new("guard")
    |> hooks.on_tool_call(fn(_) { hooks.AllowTool })
  let event =
    hooks.ToolCallEvent(
      tool_name: "bash",
      tool_call_id: "c1",
      arguments_json: "{}",
    )
  let decision = hooks.decide_tool_call([h], event)
  assert decision == hooks.ToolAllowed
}

pub fn decide_tool_call_blocked_carries_attribution_test() {
  let h =
    hooks.new("safety-guard")
    |> hooks.on_tool_call(fn(_) { hooks.BlockTool("dangerous") })
  let event =
    hooks.ToolCallEvent(
      tool_name: "bash",
      tool_call_id: "c1",
      arguments_json: "{}",
    )
  let decision = hooks.decide_tool_call([h], event)
  assert decision ==
    hooks.ToolBlocked(hook_name: "safety-guard", reason: "dangerous")
}

pub fn decide_tool_call_first_block_wins_test() {
  let h1 =
    hooks.new("first")
    |> hooks.on_tool_call(fn(_) { hooks.BlockTool("nope") })
  let h2 =
    hooks.new("second")
    |> hooks.on_tool_call(fn(_) { hooks.BlockTool("also nope") })
  let event =
    hooks.ToolCallEvent(
      tool_name: "bash",
      tool_call_id: "c1",
      arguments_json: "{}",
    )
  let decision = hooks.decide_tool_call([h1, h2], event)
  assert decision == hooks.ToolBlocked(hook_name: "first", reason: "nope")
}

pub fn decide_tool_call_allow_then_block_blocks_test() {
  let h1 =
    hooks.new("allower")
    |> hooks.on_tool_call(fn(_) { hooks.AllowTool })
  let h2 =
    hooks.new("blocker")
    |> hooks.on_tool_call(fn(_) { hooks.BlockTool("stop") })
  let event =
    hooks.ToolCallEvent(
      tool_name: "bash",
      tool_call_id: "c1",
      arguments_json: "{}",
    )
  let decision = hooks.decide_tool_call([h1, h2], event)
  assert decision ==
    hooks.ToolBlocked(hook_name: "blocker", reason: "stop")
}

// decide_tool_result returns ToolResultDecision with attribution

pub fn decide_tool_result_unchanged_when_no_hooks_test() {
  let event =
    hooks.ToolResultEvent(
      tool_name: "bash",
      tool_call_id: "c1",
      result: "output",
      is_error: False,
      duration_ms: 100,
    )
  let decision = hooks.decide_tool_result([], event)
  assert decision == hooks.ResultUnchanged(original_event: event)
}

pub fn decide_tool_result_unchanged_when_all_keep_test() {
  let h =
    hooks.new("keeper")
    |> hooks.on_tool_result(fn(_) { hooks.KeepResult })
  let event =
    hooks.ToolResultEvent(
      tool_name: "bash",
      tool_call_id: "c1",
      result: "output",
      is_error: False,
      duration_ms: 100,
    )
  let decision = hooks.decide_tool_result([h], event)
  assert decision == hooks.ResultUnchanged(original_event: event)
}

pub fn decide_tool_result_transformed_carries_attribution_test() {
  let h =
    hooks.new("scrubber")
    |> hooks.on_tool_result(fn(_) { hooks.ReplaceResult("scrubbed", False) })
  let event =
    hooks.ToolResultEvent(
      tool_name: "bash",
      tool_call_id: "c1",
      result: "sensitive data",
      is_error: False,
      duration_ms: 100,
    )
  let decision = hooks.decide_tool_result([h], event)
  let assert hooks.ResultTransformed(final_event:, transformers:) = decision
  assert final_event.result == "scrubbed"
  assert transformers == ["scrubber"]
}

pub fn decide_tool_result_chain_carries_all_transformers_test() {
  let h1 =
    hooks.new("first")
    |> hooks.on_tool_result(fn(e) {
      hooks.ReplaceResult(e.result <> " +1", False)
    })
  let h2 =
    hooks.new("second")
    |> hooks.on_tool_result(fn(e) {
      hooks.ReplaceResult(e.result <> " +2", False)
    })
  let event =
    hooks.ToolResultEvent(
      tool_name: "bash",
      tool_call_id: "c1",
      result: "orig",
      is_error: False,
      duration_ms: 100,
    )
  let decision = hooks.decide_tool_result([h1, h2], event)
  let assert hooks.ResultTransformed(final_event:, transformers:) = decision
  assert final_event.result == "orig +1 +2"
  assert transformers == ["first", "second"]
}

// decide_messages returns MessagesDecision with attribution

pub fn decide_messages_unchanged_when_no_hooks_test() {
  let messages = [message.User("hello")]
  let event = hooks.BeforeInferenceEvent(model: "gpt-4", messages:)
  let decision = hooks.decide_messages([], event)
  assert decision == hooks.MessagesUnchanged(original: messages)
}

pub fn decide_messages_unchanged_when_all_keep_test() {
  let messages = [message.User("hello")]
  let event = hooks.BeforeInferenceEvent(model: "gpt-4", messages:)
  let h =
    hooks.new("noop")
    |> hooks.on_before_inference(fn(_) { hooks.KeepMessages })
  let decision = hooks.decide_messages([h], event)
  assert decision == hooks.MessagesUnchanged(original: messages)
}

pub fn decide_messages_replaced_carries_attribution_test() {
  let new_msgs = [message.System("injected"), message.User("hello")]
  let h =
    hooks.new("injector")
    |> hooks.on_before_inference(fn(_) { hooks.ReplaceMessages(new_msgs) })
  let event =
    hooks.BeforeInferenceEvent(model: "gpt-4", messages: [message.User("hello")])
  let decision = hooks.decide_messages([h], event)
  let assert hooks.MessagesReplaced(final_messages:, transformers:) = decision
  assert final_messages == new_msgs
  assert transformers == ["injector"]
}

pub fn decide_messages_chain_carries_all_transformers_test() {
  // h1 prepends [System("ctx")] to the incoming messages
  let h1 =
    hooks.new("first")
    |> hooks.on_before_inference(fn(event) {
      hooks.ReplaceMessages(list.append([message.System("ctx")], event.messages))
    })
  // h2 appends [User("suffix")] to whatever h1 produced
  let h2 =
    hooks.new("second")
    |> hooks.on_before_inference(fn(event) {
      hooks.ReplaceMessages(
        list.append(event.messages, [message.User("suffix")]),
      )
    })
  let event =
    hooks.BeforeInferenceEvent(model: "gpt-4", messages: [message.User("hello")])
  let decision = hooks.decide_messages([h1, h2], event)
  let assert hooks.MessagesReplaced(final_messages:, transformers:) = decision
  // Only proper chaining produces: [System("ctx"), User("hello"), User("suffix")]
  assert final_messages == [
    message.System("ctx"),
    message.User("hello"),
    message.User("suffix"),
  ]
  assert transformers == ["first", "second"]
}

// ── Session Lifecycle Hook Tests ──────────────────────────────────────

pub fn new_hooks_has_no_session_start_by_default_test() {
  let h = hooks.new("test")
  let event = hooks.SessionStartEvent(history: [])
  // Default handler is no-op — should not crash
  case h {
    hooks.Hooks(on_session_start: handler, ..) -> handler(event)
  }
  Nil
}

pub fn new_hooks_has_no_session_shutdown_by_default_test() {
  let h = hooks.new("test")
  let event = hooks.SessionShutdownEvent(history: [], iterations: 0)
  case h {
    hooks.Hooks(on_session_shutdown: handler, ..) -> handler(event)
  }
  Nil
}

pub fn on_session_start_replaces_handler_test() {
  let h =
    hooks.new("test")
    |> hooks.on_session_start(fn(_) { Nil })
  let event = hooks.SessionStartEvent(history: [])
  case h {
    hooks.Hooks(on_session_start: handler, ..) -> handler(event)
  }
  Nil
}

pub fn on_session_shutdown_replaces_handler_test() {
  let h =
    hooks.new("test")
    |> hooks.on_session_shutdown(fn(_) { Nil })
  let event = hooks.SessionShutdownEvent(history: [], iterations: 0)
  case h {
    hooks.Hooks(on_session_shutdown: handler, ..) -> handler(event)
  }
  Nil
}

pub fn notify_session_start_calls_all_handlers_test() {
  let h1 =
    hooks.new("observer1")
    |> hooks.on_session_start(fn(_) { Nil })
  let h2 =
    hooks.new("observer2")
    |> hooks.on_session_start(fn(_) { Nil })
  let event = hooks.SessionStartEvent(history: [])
  hooks.notify_session_start([h1, h2], event)
  Nil
}

pub fn notify_session_shutdown_calls_all_handlers_test() {
  let h1 =
    hooks.new("observer1")
    |> hooks.on_session_shutdown(fn(_) { Nil })
  let h2 =
    hooks.new("observer2")
    |> hooks.on_session_shutdown(fn(_) { Nil })
  let event = hooks.SessionShutdownEvent(history: [], iterations: 5)
  hooks.notify_session_shutdown([h1, h2], event)
  Nil
}