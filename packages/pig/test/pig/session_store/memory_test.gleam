//// Feature tests for the in-memory SessionStore adapter.

import gleam/option.{None, Some}
import gleeunit
import pig/provider
import pig/session_store.{
  type Session, type SessionStore, Corrupt, InferenceSettingsChanged,
  MessagesAppended, ParentConflict, Session, SessionCommit, SessionStore,
}
import pig/session_store/memory
import pig_protocol/message.{User}
import pig_protocol/thinking.{High}

pub fn main() -> Nil {
  gleeunit.main()
}

/// Exercise the public adapter boundary with a fresh store and always stop it.
fn check(
  initial: Session,
  exercise: fn(SessionStore, memory.MemoryStore) -> a,
) -> a {
  let assert Ok(handle) = memory.start(initial)
  let result = exercise(memory.store(handle), handle)
  memory.stop(handle)
  result
}

fn initial_session() -> Session {
  Session(head: None, messages: [], inference_settings: None)
}

fn settings() -> provider.InferenceSettings {
  provider.with_thinking_level(High)
}

/// Verify commit appends all messages and advances head.
pub fn commit_appends_all_messages_and_advances_head_test() {
  check(initial_session(), fn(store, handle) {
    let SessionStore(commit:, ..) = store
    let assert Ok(session) =
      commit(SessionCommit(
        id: "first",
        parent: None,
        delta: MessagesAppended(first: User("one"), rest: [User("two")]),
      ))

    assert session
      == Session(
        head: Some("first"),
        messages: [User("one"), User("two")],
        inference_settings: None,
      )
    assert memory.snapshot(handle) == session
  })
}

/// Verify settings only commit updates settings and head.
pub fn settings_only_commit_updates_settings_and_head_test() {
  check(initial_session(), fn(store, handle) {
    let SessionStore(commit:, ..) = store
    let assert Ok(session) =
      commit(SessionCommit(
        id: "settings",
        parent: None,
        delta: InferenceSettingsChanged(settings()),
      ))

    assert session
      == Session(
        head: Some("settings"),
        messages: [],
        inference_settings: Some(settings()),
      )
    assert memory.snapshot(handle) == session
  })
}

/// Verify identical commit id is idempotent.
pub fn identical_commit_id_is_idempotent_test() {
  check(initial_session(), fn(store, handle) {
    let SessionStore(commit:, ..) = store
    let next =
      SessionCommit(
        id: "first",
        parent: None,
        delta: MessagesAppended(first: User("one"), rest: []),
      )
    let assert Ok(first) = commit(next)
    let assert Ok(second) = commit(next)

    assert second == first
    assert memory.snapshot(handle) == first
  })
}

/// Verify duplicate id with different delta is corrupt.
pub fn duplicate_id_with_different_delta_is_corrupt_test() {
  check(initial_session(), fn(store, handle) {
    let SessionStore(commit:, ..) = store
    let assert Ok(first) =
      commit(SessionCommit(
        id: "first",
        parent: None,
        delta: MessagesAppended(first: User("one"), rest: []),
      ))
    let assert Error(Corrupt(_)) =
      commit(SessionCommit(
        id: "first",
        parent: None,
        delta: InferenceSettingsChanged(settings()),
      ))

    assert memory.snapshot(handle) == first
  })
}

/// Verify parent conflict leaves session unchanged.
pub fn parent_conflict_leaves_session_unchanged_test() {
  check(
    Session(
      head: Some("current"),
      messages: [User("saved")],
      inference_settings: None,
    ),
    fn(store, handle) {
      let SessionStore(commit:, ..) = store
      let initial = memory.snapshot(handle)
      let assert Error(ParentConflict(expected: None, actual: Some("current"))) =
        commit(SessionCommit(
          id: "next",
          parent: None,
          delta: MessagesAppended(first: User("new"), rest: []),
        ))

      assert memory.snapshot(handle) == initial
    },
  )
}
