//// Event emission utilities.
////
//// Provides functions to emit SessionEvents to the dispatcher.
//// This module bridges events.gleam and dispatcher.gleam to avoid circular imports.

import gleam/erlang/process.{type Subject}
import pig/obs/dispatcher
import pig/obs/events

/// Send a SessionEvent to the dispatcher actor.
/// Takes the dispatcher Subject directly — only what it needs.
/// This is the primary way for the core agent code to emit observability events
/// through the dispatcher to all registered consumers (session writer, terminal, etc.).
pub fn to_dispatcher(
  dispatcher_subject: Subject(dispatcher.DispatcherMessage),
  event: events.SessionEvent,
) -> Nil {
  process.send(dispatcher_subject, dispatcher.Event(event))
}
