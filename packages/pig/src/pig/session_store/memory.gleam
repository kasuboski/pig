//// In-memory, actor-serialized implementation of the synchronous session store.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option
import gleam/otp/actor
import pig/session_store.{
  type Session, type SessionCommit, type SessionDelta, type SessionError,
  type SessionStore, Corrupt, InferenceSettingsChanged, MessagesAppended,
  ParentConflict, Session, SessionCommit, SessionStore,
}

/// A handle to an in-memory session store.
pub opaque type MemoryStore {
  MemoryStore(subject: Subject(StoreMessage))
}

type StoreMessage {
  Commit(SessionCommit, Subject(Result(Session, SessionError)))
  Snapshot(Subject(Session))
  Stop
}

type State {
  State(session: Session, commits: Dict(String, SessionCommit))
}

/// Start an in-memory store with `initial` as its durable session.
pub fn start(initial: Session) -> Result(MemoryStore, actor.StartError) {
  let builder =
    actor.new(State(session: initial, commits: dict.new()))
    |> actor.on_message(handle_message)

  case actor.start(builder) {
    Ok(started) -> Ok(MemoryStore(started.data))
    Error(error) -> Error(error)
  }
}

/// Adapt an in-memory store to the public synchronous session-store contract.
pub fn store(handle: MemoryStore) -> SessionStore {
  SessionStore(load: fn() { Ok(snapshot(handle)) }, commit: fn(next) {
    commit_session(handle, next)
  })
}

/// Return a consistent snapshot of the current session.
pub fn snapshot(handle: MemoryStore) -> Session {
  let MemoryStore(subject) = handle
  actor.call(subject, 5000, Snapshot)
}

/// Stop the store actor.
pub fn stop(handle: MemoryStore) -> Nil {
  let MemoryStore(subject) = handle
  actor.send(subject, Stop)
}

fn commit_session(
  handle: MemoryStore,
  next: SessionCommit,
) -> Result(Session, SessionError) {
  let MemoryStore(subject) = handle
  actor.call(subject, 5000, fn(reply_to) { Commit(next, reply_to) })
}

fn handle_message(state: State, message: StoreMessage) {
  case message {
    Snapshot(reply_to) -> {
      process.send(reply_to, state.session)
      actor.continue(state)
    }
    Commit(next, reply_to) -> {
      let #(result, next_state) = apply_commit(state, next)
      process.send(reply_to, result)
      actor.continue(next_state)
    }
    Stop -> actor.stop()
  }
}

fn apply_commit(
  state: State,
  next: SessionCommit,
) -> #(Result(Session, SessionError), State) {
  let SessionCommit(id:, parent:, delta:) = next
  case dict.get(state.commits, id) {
    Ok(previous) ->
      case previous.parent == parent && previous.delta == delta {
        True -> #(Ok(state.session), state)
        False -> #(
          Error(Corrupt("commit ID was reused with different contents")),
          state,
        )
      }
    Error(_) ->
      case parent == state.session.head {
        False -> #(
          Error(ParentConflict(expected: parent, actual: state.session.head)),
          state,
        )
        True -> {
          let session = apply_delta(state.session, id, delta)
          #(
            Ok(session),
            State(session:, commits: dict.insert(state.commits, id, next)),
          )
        }
      }
  }
}

fn apply_delta(session: Session, id: String, delta: SessionDelta) -> Session {
  case delta {
    MessagesAppended(first:, rest:) ->
      Session(
        head: option.Some(id),
        messages: list.append(session.messages, [first, ..rest]),
        inference_settings: session.inference_settings,
      )
    InferenceSettingsChanged(settings) ->
      Session(
        head: option.Some(id),
        messages: session.messages,
        inference_settings: option.Some(settings),
      )
  }
}
