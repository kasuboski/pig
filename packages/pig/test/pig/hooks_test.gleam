//// Hooks system tests.
////
//// Comprehensive unit tests for the hooks module following TDD principles.
//// Tests verify the renamed Hooks type (was Extension) and composition
//// functions that take List(Hooks) instead of ExtensionStack.

import pig/provider

import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit
import pig/hooks
import pig_protocol/error
import pig_protocol/message
import pig_protocol/thinking

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Builder Tests ───────────────────────────────────────────────────

/// Verify new creates hooks with name.
pub fn new_creates_hooks_with_name_test() {
  let h = hooks.new("my-hooks")
  let hooks.Hooks(name:, ..) = h
  assert name == "my-hooks"
}

/// Verify new hooks allows tools by default.
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

/// Verify new hooks keeps results by default.
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

/// Verify new hooks keeps messages by default.
pub fn new_hooks_keeps_messages_by_default_test() {
  let h = hooks.new("test")
  let messages = [message.User("hello"), message.System("system")]
  let event =
    hooks.BeforeInferenceEvent(
      model: "gpt-4",
      messages: messages,
      settings: provider.default_settings(),
    )
  let action = case h {
    hooks.Hooks(on_before_inference: handler, ..) -> handler(event)
  }
  assert action == hooks.KeepMessages
}

/// Verify on tool call replaces handler.
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

/// Verify on tool result replaces handler.
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

/// Verify on before inference replaces handler.
pub fn on_before_inference_replaces_handler_test() {
  let new_messages = [message.User("modified")]
  let h =
    hooks.new("test")
    |> hooks.on_before_inference(fn(_) { hooks.ReplaceMessages(new_messages) })
  let event =
    hooks.BeforeInferenceEvent(
      model: "gpt-4",
      messages: [
        message.User("original"),
      ],
      settings: provider.default_settings(),
    )
  let action = case h {
    hooks.Hooks(on_before_inference: handler, ..) -> handler(event)
  }
  assert action == hooks.ReplaceMessages(new_messages)
}

/// Verify on after inference replaces handler.
pub fn on_after_inference_replaces_handler_test() {
  let signal = process.new_subject()
  let h =
    hooks.new("test")
    |> hooks.on_after_inference(fn(_) { process.send(signal, Nil) })
  let event =
    hooks.AfterInferenceEvent(
      model: "gpt-4",
      message: message.Assistant("response", [], None, None),
      duration_ms: 100,
      settings: provider.default_settings(),
    )
  let _ = case h {
    hooks.Hooks(on_after_inference: handler, ..) -> handler(event)
  }
  let assert Ok(Nil) = process.receive(signal, 1000)
}

/// Verify on error replaces handler.
pub fn on_error_replaces_handler_test() {
  let signal = process.new_subject()
  let h =
    hooks.new("test")
    |> hooks.on_error(fn(_) { process.send(signal, Nil) })
  let event =
    hooks.ErrorEvent(
      model: "gpt-4",
      error: error.ApiError("test error"),
      settings: provider.default_settings(),
    )
  let _ = case h {
    hooks.Hooks(on_error: handler, ..) -> handler(event)
  }
  let assert Ok(Nil) = process.receive(signal, 1000)
}

/// Verify on complete replaces handler.
pub fn on_complete_replaces_handler_test() {
  let signal = process.new_subject()
  let h =
    hooks.new("test")
    |> hooks.on_complete(fn(_) { process.send(signal, Nil) })
  let event =
    hooks.CompleteEvent(
      model: "gpt-4",
      message: message.Assistant("final", [], None, None),
      total_iterations: 5,
    )
  let _ = case h {
    hooks.Hooks(on_complete: handler, ..) -> handler(event)
  }
  let assert Ok(Nil) = process.receive(signal, 1000)
}

// ── Composition Tests: Notification Handlers (List(Hooks)) ──────────

/// Verify notify after inference calls all handlers.
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
      message: message.Assistant("response", [], None, None),
      duration_ms: 100,
      settings: provider.default_settings(),
    )
  hooks.notify_after_inference([h1, h2], event)
  let assert Ok(Nil) = process.receive(signal, 1000)
  let assert Ok(Nil) = process.receive(signal, 1000)
}

/// Verify notify error calls all handlers.
pub fn notify_error_calls_all_handlers_test() {
  let signal = process.new_subject()
  let h1 =
    hooks.new("error_handler1")
    |> hooks.on_error(fn(_) { process.send(signal, Nil) })
  let h2 =
    hooks.new("error_handler2")
    |> hooks.on_error(fn(_) { process.send(signal, Nil) })
  let event =
    hooks.ErrorEvent(
      model: "gpt-4",
      error: error.ApiError("test error"),
      settings: provider.default_settings(),
    )
  hooks.notify_error([h1, h2], event)
  let assert Ok(Nil) = process.receive(signal, 1000)
  let assert Ok(Nil) = process.receive(signal, 1000)
}

/// Verify notify complete calls all handlers.
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
      message: message.Assistant("final", [], None, None),
      total_iterations: 5,
    )
  hooks.notify_complete([h1, h2], event)
  let assert Ok(Nil) = process.receive(signal, 1000)
  let assert Ok(Nil) = process.receive(signal, 1000)
}

// ── Action Constructor Tests ─────────────────────────────────────────

/// Verify allow tool returns allow.
pub fn allow_tool_returns_allow_test() {
  let action = hooks.allow_tool()
  assert action == hooks.AllowTool
}

/// Verify block tool returns block with reason.
pub fn block_tool_returns_block_with_reason_test() {
  let action = hooks.block_tool("not allowed")
  assert action == hooks.BlockTool("not allowed")
}

/// Verify keep result returns keep.
pub fn keep_result_returns_keep_test() {
  let action = hooks.keep_result()
  assert action == hooks.KeepResult
}

/// Verify replace result returns replace.
pub fn replace_result_returns_replace_test() {
  let action = hooks.replace_result("new content", True)
  assert action == hooks.ReplaceResult("new content", True)
}

/// Verify keep messages returns keep.
pub fn keep_messages_returns_keep_test() {
  let action = hooks.keep_messages()
  assert action == hooks.KeepMessages
}

/// Verify replace messages returns replace.
pub fn replace_messages_returns_replace_test() {
  let messages = [message.User("test")]
  let action = hooks.replace_messages(messages)
  assert action == hooks.ReplaceMessages(messages)
}

// ── Decision Type Tests ──────────────────────────────────────────────

// decide_tool_call returns ToolCallDecision with attribution

/// Verify decide tool call allows when no hooks.
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

/// Verify decide tool call allows when all allow.
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

/// Verify decide tool call blocked carries attribution.
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
  assert decision
    == hooks.ToolBlocked(hook_name: "safety-guard", reason: "dangerous")
}

/// Verify decide tool call first block wins.
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

/// Verify decide tool call allow then block blocks.
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
  assert decision == hooks.ToolBlocked(hook_name: "blocker", reason: "stop")
}

// decide_tool_result returns ToolResultDecision with attribution

/// Verify decide tool result unchanged when no hooks.
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

/// Verify decide tool result unchanged when all keep.
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

/// Verify decide tool result transformed carries attribution.
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

/// Verify decide tool result chain carries all transformers.
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

/// Verify decide messages unchanged when no hooks.
pub fn decide_messages_unchanged_when_no_hooks_test() {
  let messages = [message.User("hello")]
  let event =
    hooks.BeforeInferenceEvent(
      model: "gpt-4",
      messages:,
      settings: provider.default_settings(),
    )
  let decision = hooks.decide_messages([], event)
  assert decision == hooks.MessagesUnchanged(original: messages)
}

/// Verify decide messages unchanged when all keep.
pub fn decide_messages_unchanged_when_all_keep_test() {
  let messages = [message.User("hello")]
  let event =
    hooks.BeforeInferenceEvent(
      model: "gpt-4",
      messages:,
      settings: provider.default_settings(),
    )
  let h =
    hooks.new("noop")
    |> hooks.on_before_inference(fn(_) { hooks.KeepMessages })
  let decision = hooks.decide_messages([h], event)
  assert decision == hooks.MessagesUnchanged(original: messages)
}

/// Verify decide messages replaced carries attribution.
pub fn decide_messages_replaced_carries_attribution_test() {
  let new_msgs = [message.System("injected"), message.User("hello")]
  let h =
    hooks.new("injector")
    |> hooks.on_before_inference(fn(_) { hooks.ReplaceMessages(new_msgs) })
  let event =
    hooks.BeforeInferenceEvent(
      model: "gpt-4",
      messages: [message.User("hello")],
      settings: provider.default_settings(),
    )
  let decision = hooks.decide_messages([h], event)
  let assert hooks.MessagesReplaced(final_messages:, transformers:) = decision
  assert final_messages == new_msgs
  assert transformers == ["injector"]
}

/// Verify decide messages chain carries all transformers.
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
    hooks.BeforeInferenceEvent(
      model: "gpt-4",
      messages: [message.User("hello")],
      settings: provider.default_settings(),
    )
  let decision = hooks.decide_messages([h1, h2], event)
  let assert hooks.MessagesReplaced(final_messages:, transformers:) = decision
  // Only proper chaining produces: [System("ctx"), User("hello"), User("suffix")]
  assert final_messages
    == [
      message.System("ctx"),
      message.User("hello"),
      message.User("suffix"),
    ]
  assert transformers == ["first", "second"]
}

// ── Session Lifecycle Hook Tests ──────────────────────────────────────

/// Verify hooks keep requested settings in before inference.
pub fn hooks_keep_requested_settings_in_before_inference_test() {
  let requested = provider.with_thinking_level(thinking.Off)
  let seen = process.new_subject()
  let h =
    hooks.new("observer")
    |> hooks.on_before_inference(fn(event) {
      process.send(seen, event.settings)
      hooks.KeepMessages
    })
  let event =
    hooks.BeforeInferenceEvent(
      model: "gpt-4",
      messages: [message.User("hello")],
      settings: requested,
    )
  let assert hooks.MessagesUnchanged(_) = hooks.decide_messages([h], event)
  let assert Ok(settings) = process.receive(seen, 1000)
  assert settings == requested
}

/// Verify new hooks has no session start by default.
pub fn new_hooks_has_no_session_start_by_default_test() {
  let h = hooks.new("test")
  let event = hooks.SessionStartEvent(history: [])
  // Default handler is no-op — should not crash
  case h {
    hooks.Hooks(on_session_start: handler, ..) -> handler(event)
  }
  Nil
}

/// Verify new hooks has no session shutdown by default.
pub fn new_hooks_has_no_session_shutdown_by_default_test() {
  let h = hooks.new("test")
  let event = hooks.SessionShutdownEvent(history: [], iterations: 0)
  case h {
    hooks.Hooks(on_session_shutdown: handler, ..) -> handler(event)
  }
  Nil
}

/// Verify on session start replaces handler.
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

/// Verify on session shutdown replaces handler.
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

/// Verify notify session start calls all handlers.
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

/// Verify notify session shutdown calls all handlers.
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
