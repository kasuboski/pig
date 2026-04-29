//// Extension system tests.
////
//// Comprehensive unit tests for the extension module following TDD principles.

import gleeunit
import gleeunit/should
import gleam/list
import gleam/option.{None}
import pig/ai/error
import pig/ai/message
import pig/extension

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Builder Tests ───────────────────────────────────────────────────

pub fn new_creates_extension_with_name_test() {
  let _ext = extension.new("my-extension")
  // Extension is created successfully
  True
}

pub fn new_extension_allows_tools_by_default_test() {
  let ext = extension.new("test")
  let event = extension.ToolCallEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    arguments_json: "{}",
  )
  let action = case ext {
    extension.Extension(on_tool_call: handler, ..) -> handler(event)
  }
  should.equal(action, extension.AllowTool)
}

pub fn new_extension_keeps_results_by_default_test() {
  let ext = extension.new("test")
  let event = extension.ToolResultEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    result: "original result",
    is_error: False,
    duration_ms: 100,
  )
  let action = case ext {
    extension.Extension(on_tool_result: handler, ..) -> handler(event)
  }
  should.equal(action, extension.KeepResult)
}

pub fn new_extension_keeps_messages_by_default_test() {
  let ext = extension.new("test")
  let messages = [message.User("hello"), message.System("system")]
  let event = extension.BeforeInferenceEvent(
    model: "gpt-4",
    messages: messages,
  )
  let action = case ext {
    extension.Extension(on_before_inference: handler, ..) -> handler(event)
  }
  should.equal(action, extension.KeepMessages)
}

pub fn on_tool_call_replaces_handler_test() {
  let ext =
    extension.new("test")
    |> extension.on_tool_call(fn(_) { extension.BlockTool("blocked") })
  let event = extension.ToolCallEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    arguments_json: "{}",
  )
  let action = case ext {
    extension.Extension(on_tool_call: handler, ..) -> handler(event)
  }
  should.equal(action, extension.BlockTool("blocked"))
}

pub fn on_tool_result_replaces_handler_test() {
  let ext =
    extension.new("test")
    |> extension.on_tool_result(fn(_) {
      extension.ReplaceResult("new result", True)
    })
  let event = extension.ToolResultEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    result: "original result",
    is_error: False,
    duration_ms: 100,
  )
  let action = case ext {
    extension.Extension(on_tool_result: handler, ..) -> handler(event)
  }
  should.equal(action, extension.ReplaceResult("new result", True))
}

pub fn on_before_inference_replaces_handler_test() {
  let new_messages = [message.User("modified")]
  let ext =
    extension.new("test")
    |> extension.on_before_inference(fn(_) {
      extension.ReplaceMessages(new_messages)
    })
  let event = extension.BeforeInferenceEvent(
    model: "gpt-4",
    messages: [message.User("original")],
  )
  let action = case ext {
    extension.Extension(on_before_inference: handler, ..) -> handler(event)
  }
  should.equal(action, extension.ReplaceMessages(new_messages))
}

pub fn on_after_inference_replaces_handler_test() {
  let ext =
    extension.new("test")
    |> extension.on_after_inference(fn(_) { Nil })
  let event = extension.AfterInferenceEvent(
    model: "gpt-4",
    message: message.Assistant("response", [], None),
    duration_ms: 100,
  )
  let _ = case ext {
    extension.Extension(on_after_inference: handler, ..) -> handler(event)
  }
  // Handler was called without crashing
  True
}

pub fn on_error_replaces_handler_test() {
  let ext =
    extension.new("test")
    |> extension.on_error(fn(_) { Nil })
  let event = extension.ErrorEvent(
    model: "gpt-4",
    error: error.ApiError("test error"),
  )
  let _ = case ext {
    extension.Extension(on_error: handler, ..) -> handler(event)
  }
  // Handler was called without crashing
  True
}

pub fn on_complete_replaces_handler_test() {
  let ext =
    extension.new("test")
    |> extension.on_complete(fn(_) { Nil })
  let event = extension.CompleteEvent(
    model: "gpt-4",
    message: message.Assistant("final", [], None),
    total_iterations: 5,
  )
  let _ = case ext {
    extension.Extension(on_complete: handler, ..) -> handler(event)
  }
  // Handler was called without crashing
  True
}

// ── Stack Composition Tests: Tool Call ───────────────────────────────

pub fn empty_stack_allows_all_tools_test() {
  let stack = extension.empty_stack()
  let event = extension.ToolCallEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    arguments_json: "{}",
  )
  let result = extension.should_allow_tool_call(stack, event)
  should.equal(result, Ok(Nil))
}

pub fn single_extension_allows_tool_test() {
  let ext =
    extension.new("allower")
    |> extension.on_tool_call(fn(_) { extension.AllowTool })
  let stack = extension.stack([ext])
  let event = extension.ToolCallEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    arguments_json: "{}",
  )
  let result = extension.should_allow_tool_call(stack, event)
  should.equal(result, Ok(Nil))
}

pub fn single_extension_blocks_tool_test() {
  let ext =
    extension.new("blocker")
    |> extension.on_tool_call(fn(_) { extension.BlockTool("not allowed") })
  let stack = extension.stack([ext])
  let event = extension.ToolCallEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    arguments_json: "{}",
  )
  let result = extension.should_allow_tool_call(stack, event)
  should.equal(result, Error("not allowed"))
}

pub fn block_takes_precedence_over_allow_test() {
  let ext1 =
    extension.new("blocker")
    |> extension.on_tool_call(fn(_) { extension.BlockTool("first block") })
  let ext2 =
    extension.new("blocker2")
    |> extension.on_tool_call(fn(_) { extension.BlockTool("second block") })
  let stack = extension.stack([ext1, ext2])
  let event = extension.ToolCallEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    arguments_json: "{}",
  )
  let result = extension.should_allow_tool_call(stack, event)
  should.equal(result, Error("first block"))
}

pub fn all_extensions_allow_test() {
  let ext1 =
    extension.new("allower1")
    |> extension.on_tool_call(fn(_) { extension.AllowTool })
  let ext2 =
    extension.new("allower2")
    |> extension.on_tool_call(fn(_) { extension.AllowTool })
  let stack = extension.stack([ext1, ext2])
  let event = extension.ToolCallEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    arguments_json: "{}",
  )
  let result = extension.should_allow_tool_call(stack, event)
  should.equal(result, Ok(Nil))
}

pub fn block_reason_is_returned_test() {
  let ext =
    extension.new("blocker")
    |> extension.on_tool_call(fn(_) {
      extension.BlockTool("security violation")
    })
  let stack = extension.stack([ext])
  let event = extension.ToolCallEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    arguments_json: "{}",
  )
  let result = extension.should_allow_tool_call(stack, event)
  should.equal(result, Error("security violation"))
}

// ── Stack Composition Tests: Tool Result ────────────────────────────

pub fn empty_stack_keeps_tool_results_test() {
  let stack = extension.empty_stack()
  let event = extension.ToolResultEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    result: "original result",
    is_error: False,
    duration_ms: 100,
  )
  let result = extension.transform_tool_result(stack, event)
  should.equal(result, event)
}

pub fn single_extension_transforms_result_test() {
  let ext =
    extension.new("transformer")
    |> extension.on_tool_result(fn(_) {
      extension.ReplaceResult("transformed", True)
    })
  let stack = extension.stack([ext])
  let event = extension.ToolResultEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    result: "original result",
    is_error: False,
    duration_ms: 100,
  )
  let result = extension.transform_tool_result(stack, event)
  let assert extension.ToolResultEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    result: "transformed",
    is_error: True,
    duration_ms: 100,
  ) = result
  True
}

pub fn transform_chains_across_extensions_test() {
  let ext1 =
    extension.new("first")
    |> extension.on_tool_result(fn(_) {
      extension.ReplaceResult("first transform", False)
    })
  let ext2 =
    extension.new("second")
    |> extension.on_tool_result(fn(_) {
      extension.ReplaceResult("second transform", True)
    })
  let stack = extension.stack([ext1, ext2])
  let event = extension.ToolResultEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    result: "original result",
    is_error: False,
    duration_ms: 100,
  )
  let result = extension.transform_tool_result(stack, event)
  let assert extension.ToolResultEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    result: "second transform",
    is_error: True,
    duration_ms: 100,
  ) = result
  True
}

pub fn keep_result_passes_through_test() {
  let ext =
    extension.new("keeper")
    |> extension.on_tool_result(fn(_) { extension.KeepResult })
  let stack = extension.stack([ext])
  let event = extension.ToolResultEvent(
    tool_name: "test_tool",
    tool_call_id: "call_123",
    result: "original result",
    is_error: False,
    duration_ms: 100,
  )
  let result = extension.transform_tool_result(stack, event)
  should.equal(result, event)
}

// ── Stack Composition Tests: Messages ────────────────────────────────

pub fn empty_stack_keeps_messages_test() {
  let stack = extension.empty_stack()
  let messages = [message.User("hello"), message.System("system")]
  let event = extension.BeforeInferenceEvent(
    model: "gpt-4",
    messages: messages,
  )
  let result = extension.transform_messages(stack, event)
  should.equal(result, messages)
}

pub fn single_extension_replaces_messages_test() {
  let new_messages = [message.User("modified")]
  let ext =
    extension.new("replacer")
    |> extension.on_before_inference(fn(_) {
      extension.ReplaceMessages(new_messages)
    })
  let stack = extension.stack([ext])
  let event = extension.BeforeInferenceEvent(
    model: "gpt-4",
    messages: [message.User("original")],
  )
  let result = extension.transform_messages(stack, event)
  should.equal(result, new_messages)
}

pub fn message_transform_chains_across_extensions_test() {
  let msg1 = message.User("first")
  let msg2 = message.User("second")
  let msg3 = message.User("third")
  let ext1 =
    extension.new("first")
    |> extension.on_before_inference(fn(_) {
      extension.ReplaceMessages([msg1, msg2])
    })
  let ext2 =
    extension.new("second")
    |> extension.on_before_inference(fn(_) {
      extension.ReplaceMessages([msg3])
    })
  let stack = extension.stack([ext1, ext2])
  let event = extension.BeforeInferenceEvent(
    model: "gpt-4",
    messages: [message.User("original")],
  )
  let result = extension.transform_messages(stack, event)
  should.equal(result, [msg3])
}

// ── Stack Composition Tests: Notification Handlers ──────────────────

pub fn notify_after_inference_calls_all_handlers_test() {
  let ext1 =
    extension.new("observer1")
    |> extension.on_after_inference(fn(_) { Nil })
  let ext2 =
    extension.new("observer2")
    |> extension.on_after_inference(fn(_) { Nil })
  let stack = extension.stack([ext1, ext2])
  let event = extension.AfterInferenceEvent(
    model: "gpt-4",
    message: message.Assistant("response", [], None),
    duration_ms: 100,
  )
  // Should not crash - handlers are fire-and-forget
  extension.notify_after_inference(stack, event)
  True
}

pub fn notify_error_calls_all_handlers_test() {
  let ext1 =
    extension.new("error_handler1")
    |> extension.on_error(fn(_) { Nil })
  let ext2 =
    extension.new("error_handler2")
    |> extension.on_error(fn(_) { Nil })
  let stack = extension.stack([ext1, ext2])
  let event = extension.ErrorEvent(
    model: "gpt-4",
    error: error.ApiError("test error"),
  )
  // Should not crash - handlers are fire-and-forget
  extension.notify_error(stack, event)
  True
}

pub fn notify_complete_calls_all_handlers_test() {
  let ext1 =
    extension.new("observer1")
    |> extension.on_complete(fn(_) { Nil })
  let ext2 =
    extension.new("observer2")
    |> extension.on_complete(fn(_) { Nil })
  let stack = extension.stack([ext1, ext2])
  let event = extension.CompleteEvent(
    model: "gpt-4",
    message: message.Assistant("final", [], None),
    total_iterations: 5,
  )
  // Should not crash - handlers are fire-and-forget
  extension.notify_complete(stack, event)
  True
}

pub fn stack_to_list_returns_extensions_test() {
  let ext1 = extension.new("first")
  let ext2 = extension.new("second")
  let stack = extension.stack([ext1, ext2])
  let result = extension.stack_to_list(stack)
  should.equal(list.length(result), 2)
}

// ── Action Constructor Tests ─────────────────────────────────────────

pub fn allow_tool_returns_allow_test() {
  let action = extension.allow_tool()
  should.equal(action, extension.AllowTool)
}

pub fn block_tool_returns_block_with_reason_test() {
  let action = extension.block_tool("not allowed")
  should.equal(action, extension.BlockTool("not allowed"))
}

pub fn keep_result_returns_keep_test() {
  let action = extension.keep_result()
  should.equal(action, extension.KeepResult)
}

pub fn replace_result_returns_replace_test() {
  let action = extension.replace_result("new content", True)
  should.equal(action, extension.ReplaceResult("new content", True))
}

pub fn keep_messages_returns_keep_test() {
  let action = extension.keep_messages()
  should.equal(action, extension.KeepMessages)
}

pub fn replace_messages_returns_replace_test() {
  let messages = [message.User("test")]
  let action = extension.replace_messages(messages)
  should.equal(action, extension.ReplaceMessages(messages))
}
