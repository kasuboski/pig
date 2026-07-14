//// Durable session storage types for atomic agent-state transitions.

import gleam/bit_array
import gleam/crypto
import gleam/option.{type Option}
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

/// The durable transcript and its current commit head.
pub type Session {
  Session(head: Option(String), messages: List(Message))
}

/// An atomic delta to append to a session transcript.
pub type SessionCommit {
  SessionCommit(id: String, parent: Option(String), messages: List(Message))
}

/// Create a commit with a fresh opaque ID, its expected parent, and its delta.
///
/// The ID is generated independently of the messages, so commits with identical
/// contents still have distinct identities.
pub fn new_commit(
  parent: Option(String),
  messages: List(Message),
) -> SessionCommit {
  SessionCommit(
    id: "commit-"
      <> bit_array.base64_url_encode(crypto.strong_random_bytes(16), False),
    parent:,
    messages:,
  )
}

/// A synchronous durable store bound to one logical session.
///
/// `commit` atomically persists the complete message delta and returns the
/// resulting session. Recommitting an identical commit ID is idempotent.
pub type SessionStore {
  SessionStore(
    load: fn() -> Result(Session, SessionError),
    commit: fn(SessionCommit) -> Result(Session, SessionError),
  )
}
