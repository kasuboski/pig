//// Extension system for pig agent lifecycle hooks.
////
//// Extensions allow library users to hook into agent lifecycle events:
//// - Blocking tool calls
//// - Transforming results
//// - Reacting to events
////
//// Extensions are composed into a stack that runs handlers in order.

import gleam/list
import pig/ai/error.{type AiError}
import pig/ai/message.{type Message}

// ── Event Types ─────────────────────────────────────────────────────

/// Before the provider is called. Handlers can modify the messages sent.
pub type BeforeInferenceEvent {
  BeforeInferenceEvent(
    model: String,
    messages: List(Message),
  )
}

/// What a before_inference handler returns.
pub type BeforeInferenceAction {
  KeepMessages
  ReplaceMessages(messages: List(Message))
}

/// After the provider responds.
pub type AfterInferenceEvent {
  AfterInferenceEvent(
    model: String,
    message: Message,
    duration_ms: Int,
  )
}

/// Before a tool executes. Handlers can block it.
pub type ToolCallEvent {
  ToolCallEvent(
    tool_name: String,
    tool_call_id: String,
    arguments_json: String,
  )
}

/// What a tool_call handler returns.
pub type ToolCallAction {
  AllowTool
  BlockTool(reason: String)
}

/// After a tool finishes. Handlers can transform the result.
pub type ToolResultEvent {
  ToolResultEvent(
    tool_name: String,
    tool_call_id: String,
    result: String,
    is_error: Bool,
    duration_ms: Int,
  )
}

/// What a tool_result handler returns.
pub type ToolResultAction {
  KeepResult
  ReplaceResult(content: String, is_error: Bool)
}

/// An error occurred during inference.
pub type ErrorEvent {
  ErrorEvent(
    model: String,
    error: AiError,
  )
}

/// The agent loop completed with a final message.
pub type CompleteEvent {
  CompleteEvent(
    model: String,
    message: Message,
    total_iterations: Int,
  )
}

// ── Extension Type ──────────────────────────────────────────────────

/// A named extension with handlers for each lifecycle hook.
/// Construct with `new(name)` and add handlers with `on_*` builder functions.
/// Default handlers are no-ops: AllowTool, KeepResult, KeepMessages, fn(_) { Nil }.
pub type Extension {
  Extension(
    name: String,
    on_before_inference: fn(BeforeInferenceEvent) -> BeforeInferenceAction,
    on_after_inference: fn(AfterInferenceEvent) -> Nil,
    on_tool_call: fn(ToolCallEvent) -> ToolCallAction,
    on_tool_result: fn(ToolResultEvent) -> ToolResultAction,
    on_error: fn(ErrorEvent) -> Nil,
    on_complete: fn(CompleteEvent) -> Nil,
  )
}

// ── Extension Stack Type ─────────────────────────────────────────────

/// A composed list of extensions. Created with `stack(extensions)`.
/// The stack provides composition functions that run all extensions in order
/// with specific semantics per event type.
pub type ExtensionStack {
  ExtensionStack(extensions: List(Extension))
}

// ── Extension Builder Functions ───────────────────────────────────────

/// Creates an extension with all no-op handlers.
pub fn new(name: String) -> Extension {
  Extension(
    name: name,
    on_before_inference: fn(_) { KeepMessages },
    on_after_inference: fn(_) { Nil },
    on_tool_call: fn(_) { AllowTool },
    on_tool_result: fn(_) { KeepResult },
    on_error: fn(_) { Nil },
    on_complete: fn(_) { Nil },
  )
}

/// Sets the before_inference handler.
pub fn on_before_inference(
  ext: Extension,
  handler: fn(BeforeInferenceEvent) -> BeforeInferenceAction,
) -> Extension {
  Extension(..ext, on_before_inference: handler)
}

/// Sets the after_inference handler.
pub fn on_after_inference(
  ext: Extension,
  handler: fn(AfterInferenceEvent) -> Nil,
) -> Extension {
  Extension(..ext, on_after_inference: handler)
}

/// Sets the tool_call handler.
pub fn on_tool_call(
  ext: Extension,
  handler: fn(ToolCallEvent) -> ToolCallAction,
) -> Extension {
  Extension(..ext, on_tool_call: handler)
}

/// Sets the tool_result handler.
pub fn on_tool_result(
  ext: Extension,
  handler: fn(ToolResultEvent) -> ToolResultAction,
) -> Extension {
  Extension(..ext, on_tool_result: handler)
}

/// Sets the error handler.
pub fn on_error(
  ext: Extension,
  handler: fn(ErrorEvent) -> Nil,
) -> Extension {
  Extension(..ext, on_error: handler)
}

/// Sets the complete handler.
pub fn on_complete(
  ext: Extension,
  handler: fn(CompleteEvent) -> Nil,
) -> Extension {
  Extension(..ext, on_complete: handler)
}

// ── Action Constructors (Convenience) ─────────────────────────────────

/// Returns an action that allows a tool call to proceed.
pub fn allow_tool() -> ToolCallAction {
  AllowTool
}

/// Returns an action that blocks a tool call with the given reason.
pub fn block_tool(reason: String) -> ToolCallAction {
  BlockTool(reason)
}

/// Returns an action that keeps the original tool result.
pub fn keep_result() -> ToolResultAction {
  KeepResult
}

/// Returns an action that replaces the tool result.
pub fn replace_result(content: String, is_error: Bool) -> ToolResultAction {
  ReplaceResult(content, is_error)
}

/// Returns an action that keeps the original messages.
pub fn keep_messages() -> BeforeInferenceAction {
  KeepMessages
}

/// Returns an action that replaces the messages.
pub fn replace_messages(messages: List(Message)) -> BeforeInferenceAction {
  ReplaceMessages(messages)
}

// ── Stack Functions ─────────────────────────────────────────────────

/// Creates an extension stack from a list of extensions.
pub fn stack(extensions: List(Extension)) -> ExtensionStack {
  ExtensionStack(extensions: extensions)
}

/// Creates an empty extension stack.
pub fn empty_stack() -> ExtensionStack {
  ExtensionStack(extensions: [])
}

/// Run all tool_call handlers. First BlockTool wins, returns Error(reason).
/// If all AllowTool, returns Ok(Nil).
pub fn should_allow_tool_call(
  stack: ExtensionStack,
  event: ToolCallEvent,
) -> Result(Nil, String) {
  case stack.extensions {
    [] -> Ok(Nil)
    extensions -> {
      let results = list.map(extensions, fn(ext) {
        ext.on_tool_call(event)
      })
      case find_first_block(results) {
        Ok(reason) -> Error(reason)
        Error(Nil) -> Ok(Nil)
      }
    }
  }
}

fn find_first_block(actions: List(ToolCallAction)) -> Result(String, Nil) {
  case actions {
    [] -> Error(Nil)
    [action, ..rest] -> {
      case action {
        BlockTool(reason) -> Ok(reason)
        AllowTool -> find_first_block(rest)
      }
    }
  }
}

/// Run all tool_result handlers. Chain ReplaceResult transformations.
pub fn transform_tool_result(
  stack: ExtensionStack,
  event: ToolResultEvent,
) -> ToolResultEvent {
  case stack.extensions {
    [] -> event
    extensions -> {
      list.fold(extensions, event, fn(acc, ext) {
        let action = ext.on_tool_result(acc)
        case action {
          KeepResult -> acc
          ReplaceResult(content, is_error) ->
            ToolResultEvent(
              tool_name: acc.tool_name,
              tool_call_id: acc.tool_call_id,
              result: content,
              is_error: is_error,
              duration_ms: acc.duration_ms,
            )
        }
      })
    }
  }
}

/// Run all before_inference handlers. Chain ReplaceMessages transformations.
pub fn transform_messages(
  stack: ExtensionStack,
  event: BeforeInferenceEvent,
) -> List(Message) {
  case stack.extensions {
    [] -> event.messages
    extensions -> {
      let initial_event = event
      let final_event =
        list.fold(extensions, initial_event, fn(acc, ext) {
          let action = ext.on_before_inference(acc)
          case action {
            KeepMessages -> acc
            ReplaceMessages(messages) ->
              BeforeInferenceEvent(
                model: acc.model,
                messages: messages,
              )
          }
        })
      final_event.messages
    }
  }
}

/// Run all after_inference handlers (fire-and-forget).
pub fn notify_after_inference(
  stack: ExtensionStack,
  event: AfterInferenceEvent,
) -> Nil {
  case stack.extensions {
    [] -> Nil
    extensions -> {
      let _ = list.map(extensions, fn(ext) {
        ext.on_after_inference(event)
      })
      Nil
    }
  }
}

/// Run all error handlers (fire-and-forget).
pub fn notify_error(
  stack: ExtensionStack,
  event: ErrorEvent,
) -> Nil {
  case stack.extensions {
    [] -> Nil
    extensions -> {
      let _ = list.map(extensions, fn(ext) {
        ext.on_error(event)
      })
      Nil
    }
  }
}

/// Run all complete handlers (fire-and-forget).
pub fn notify_complete(
  stack: ExtensionStack,
  event: CompleteEvent,
) -> Nil {
  case stack.extensions {
    [] -> Nil
    extensions -> {
      let _ = list.map(extensions, fn(ext) {
        ext.on_complete(event)
      })
      Nil
    }
  }
}

/// Returns the list of extensions in the stack.
pub fn stack_to_list(stack: ExtensionStack) -> List(Extension) {
  stack.extensions
}
