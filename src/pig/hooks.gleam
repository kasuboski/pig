//// Hooks system for pig agent lifecycle mediation.
////
//// Hooks allow library users to intercept agent lifecycle events:
//// - Blocking tool calls
//// - Transforming results
//// - Reacting to events
////
//// Hooks are composed as a List(Hooks) — no wrapper type needed.
//// Composition functions run handlers in order with per-event semantics.

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

/// Fired when a session starts (after replay if applicable).
pub type SessionStartEvent {
  SessionStartEvent(history: List(Message))
}

/// Fired when a session shuts down (actor stops).
pub type SessionShutdownEvent {
  SessionShutdownEvent(history: List(Message), iterations: Int)
}

// ── Hooks Type ──────────────────────────────────────────────────────

/// A named set of lifecycle callbacks for mediating the agent loop.
/// Construct with `new(name)` and add handlers with `on_*` builder functions.
/// Default handlers are no-ops: AllowTool, KeepResult, KeepMessages, fn(_) { Nil }.
pub type Hooks {
  Hooks(
    name: String,
    on_session_start: fn(SessionStartEvent) -> Nil,
    on_session_shutdown: fn(SessionShutdownEvent) -> Nil,
    on_before_inference: fn(BeforeInferenceEvent) -> BeforeInferenceAction,
    on_after_inference: fn(AfterInferenceEvent) -> Nil,
    on_tool_call: fn(ToolCallEvent) -> ToolCallAction,
    on_tool_result: fn(ToolResultEvent) -> ToolResultAction,
    on_error: fn(ErrorEvent) -> Nil,
    on_complete: fn(CompleteEvent) -> Nil,
  )
}

// ── Builder Functions ───────────────────────────────────────────────

/// Creates hooks with all no-op handlers.
pub fn new(name: String) -> Hooks {
  Hooks(
    name: name,
    on_session_start: fn(_) { Nil },
    on_session_shutdown: fn(_) { Nil },
    on_before_inference: fn(_) { KeepMessages },
    on_after_inference: fn(_) { Nil },
    on_tool_call: fn(_) { AllowTool },
    on_tool_result: fn(_) { KeepResult },
    on_error: fn(_) { Nil },
    on_complete: fn(_) { Nil },
  )
}

/// Sets the session_start handler.
pub fn on_session_start(
  h: Hooks,
  handler: fn(SessionStartEvent) -> Nil,
) -> Hooks {
  Hooks(..h, on_session_start: handler)
}

/// Sets the session_shutdown handler.
pub fn on_session_shutdown(
  h: Hooks,
  handler: fn(SessionShutdownEvent) -> Nil,
) -> Hooks {
  Hooks(..h, on_session_shutdown: handler)
}

/// Sets the before_inference handler.
pub fn on_before_inference(
  h: Hooks,
  handler: fn(BeforeInferenceEvent) -> BeforeInferenceAction,
) -> Hooks {
  Hooks(..h, on_before_inference: handler)
}

/// Sets the after_inference handler.
pub fn on_after_inference(
  h: Hooks,
  handler: fn(AfterInferenceEvent) -> Nil,
) -> Hooks {
  Hooks(..h, on_after_inference: handler)
}

/// Sets the tool_call handler.
pub fn on_tool_call(
  h: Hooks,
  handler: fn(ToolCallEvent) -> ToolCallAction,
) -> Hooks {
  Hooks(..h, on_tool_call: handler)
}

/// Sets the tool_result handler.
pub fn on_tool_result(
  h: Hooks,
  handler: fn(ToolResultEvent) -> ToolResultAction,
) -> Hooks {
  Hooks(..h, on_tool_result: handler)
}

/// Sets the error handler.
pub fn on_error(
  h: Hooks,
  handler: fn(ErrorEvent) -> Nil,
) -> Hooks {
  Hooks(..h, on_error: handler)
}

/// Sets the complete handler.
pub fn on_complete(
  h: Hooks,
  handler: fn(CompleteEvent) -> Nil,
) -> Hooks {
  Hooks(..h, on_complete: handler)
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

// ── Decision Types ──────────────────────────────────────────────────

/// Decision from tool_call hooks. Core loop pattern-matches to decide
/// whether to execute or create an error Tool message.
pub type ToolCallDecision {
  ToolAllowed
  ToolBlocked(extension_name: String, reason: String)
}

/// Decision from tool_result hooks. Carries attribution for observability.
pub type ToolResultDecision {
  ResultUnchanged(original_event: ToolResultEvent)
  ResultTransformed(
    final_event: ToolResultEvent,
    transformers: List(String),
  )
}

/// Decision from before_inference hooks. Carries attribution for observability.
pub type MessagesDecision {
  MessagesUnchanged(original: List(Message))
  MessagesReplaced(
    final_messages: List(Message),
    transformers: List(String),
  )
}

// ── Decision Composition Functions ──────────────────────────────────

/// Decide whether a tool call is allowed. First BlockTool wins.
/// Returns ToolBlocked with the blocker's name and reason for attribution.
pub fn decide_tool_call(
  hooks_list: List(Hooks),
  event: ToolCallEvent,
) -> ToolCallDecision {
  find_blocking_hook(hooks_list, event)
}

fn find_blocking_hook(
  hooks_list: List(Hooks),
  event: ToolCallEvent,
) -> ToolCallDecision {
  case hooks_list {
    [] -> ToolAllowed
    [h, ..rest] -> {
      case h.on_tool_call(event) {
        BlockTool(reason) -> ToolBlocked(extension_name: h.name, reason:)
        AllowTool -> find_blocking_hook(rest, event)
      }
    }
  }
}

/// Decide the final tool result. Chains ReplaceResult transformations.
/// Returns ResultTransformed with all transformer names for observability.
pub fn decide_tool_result(
  hooks_list: List(Hooks),
  event: ToolResultEvent,
) -> ToolResultDecision {
  let #(final_event, transformers) =
    list.fold(hooks_list, #(event, []), fn(acc, h) {
      let #(ev, names) = acc
      let action = h.on_tool_result(ev)
      case action {
        KeepResult -> #(ev, names)
        ReplaceResult(content, is_error) ->
          #(
            ToolResultEvent(
              tool_name: ev.tool_name,
              tool_call_id: ev.tool_call_id,
              result: content,
              is_error: is_error,
              duration_ms: ev.duration_ms,
            ),
            list.append(names, [h.name]),
          )
      }
    })
  case transformers {
    [] -> ResultUnchanged(original_event: event)
    _ -> ResultTransformed(final_event:, transformers:)
  }
}

/// Decide the final messages for inference. Chains ReplaceMessages.
/// Returns MessagesReplaced with all transformer names for observability.
pub fn decide_messages(
  hooks_list: List(Hooks),
  event: BeforeInferenceEvent,
) -> MessagesDecision {
  let #(final_event, transformers) =
    list.fold(hooks_list, #(event, []), fn(acc, h) {
      let #(ev, names) = acc
      let action = h.on_before_inference(ev)
      case action {
        KeepMessages -> #(ev, names)
        ReplaceMessages(messages) ->
          #(
            BeforeInferenceEvent(model: ev.model, messages:),
            list.append(names, [h.name]),
          )
      }
    })
  case transformers {
    [] -> MessagesUnchanged(original: event.messages)
    _ -> MessagesReplaced(final_messages: final_event.messages, transformers:)
  }
}

// ── Fire-and-Forget Notification Functions ─────────────────────────

/// Run all after_inference handlers (fire-and-forget).
pub fn notify_after_inference(
  hooks_list: List(Hooks),
  event: AfterInferenceEvent,
) -> Nil {
  let _ = list.map(hooks_list, fn(h) {
    h.on_after_inference(event)
  })
  Nil
}

/// Run all error handlers (fire-and-forget).
pub fn notify_error(
  hooks_list: List(Hooks),
  event: ErrorEvent,
) -> Nil {
  let _ = list.map(hooks_list, fn(h) {
    h.on_error(event)
  })
  Nil
}

/// Run all complete handlers (fire-and-forget).
pub fn notify_complete(
  hooks_list: List(Hooks),
  event: CompleteEvent,
) -> Nil {
  let _ = list.map(hooks_list, fn(h) {
    h.on_complete(event)
  })
  Nil
}

/// Run all session_start handlers (fire-and-forget).
pub fn notify_session_start(
  hooks_list: List(Hooks),
  event: SessionStartEvent,
) -> Nil {
  let _ = list.map(hooks_list, fn(h) {
    h.on_session_start(event)
  })
  Nil
}

/// Run all session_shutdown handlers (fire-and-forget).
pub fn notify_session_shutdown(
  hooks_list: List(Hooks),
  event: SessionShutdownEvent,
) -> Nil {
  let _ = list.map(hooks_list, fn(h) {
    h.on_session_shutdown(event)
  })
  Nil
}
