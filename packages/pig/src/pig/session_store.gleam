//// Durable session storage types for atomic agent-state transitions.

import gleam/bit_array
import gleam/crypto
import gleam/option.{type Option}
import pig/provider.{type InferenceSettings}
import pig_protocol/message.{type Message}

/// Errors returned while loading or committing a durable session.
pub type SessionError {
  /// The store could not be reached or complete an operation.
  Unavailable(message: String)
  /// Stored data is corrupt, including a commit ID reused with different contents.
  Corrupt(message: String)
  /// A commit's expected parent does not match the session's current head.
  ParentConflict(expected: Option(String), actual: Option(String))
  /// The proposed commit is invalid and cannot be stored.
  InvalidCommit(message: String)
}

/// The durable transcript, its current commit head, and persisted settings.
pub type Session {
  Session(
    head: Option(String),
    messages: List(Message),
    inference_settings: Option(InferenceSettings),
  )
}

/// An atomic change to a durable session.
pub type SessionDelta {
  /// Append one or more messages to the durable transcript.
  MessagesAppended(messages: List(Message))
  /// Replace the durable inference settings.
  InferenceSettingsChanged(settings: InferenceSettings)
}

/// A durable, idempotently identifiable session transition.
pub type SessionCommit {
  SessionCommit(id: String, parent: Option(String), delta: SessionDelta)
}

/// Create a message commit with a fresh opaque ID and its expected parent.
pub fn new_commit(
  parent: Option(String),
  messages: List(Message),
) -> SessionCommit {
  SessionCommit(
    id: fresh_commit_id(),
    parent:,
    delta: MessagesAppended(messages),
  )
}

/// Create an inference-settings commit with a fresh opaque ID and its expected parent.
pub fn new_settings_commit(
  parent: Option(String),
  settings: InferenceSettings,
) -> SessionCommit {
  SessionCommit(
    id: fresh_commit_id(),
    parent:,
    delta: InferenceSettingsChanged(settings),
  )
}

fn fresh_commit_id() -> String {
  "commit-"
  <> bit_array.base64_url_encode(crypto.strong_random_bytes(16), False)
}

/// A synchronous durable store bound to one logical session.
pub type SessionStore {
  SessionStore(
    load: fn() -> Result(Session, SessionError),
    commit: fn(SessionCommit) -> Result(Session, SessionError),
  )
}
