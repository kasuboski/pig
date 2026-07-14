//// Feature tests for the in-memory SessionStore adapter.

import gleam/option.{None, Some}
import gleeunit
import pig/session_store.{
  type Session, type SessionStore, Corrupt, InvalidCommit, ParentConflict,
  Session, SessionCommit, SessionStore,
}
import pig/session_store/memory
import pig_protocol/message.{User}

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

pub fn commit_appends_all_messages_and_advances_head_test() {
  check(Session(head: None, messages: []), fn(store, handle) {
    let SessionStore(commit:, ..) = store
    let assert Ok(session) =
      commit(
        SessionCommit(id: "first", parent: None, messages: [
          User("one"),
          User("two"),
        ]),
      )

    assert session
      == Session(head: Some("first"), messages: [User("one"), User("two")])
    assert memory.snapshot(handle) == session
  })
}

pub fn identical_commit_id_is_idempotent_test() {
  check(Session(head: None, messages: []), fn(store, handle) {
    let SessionStore(commit:, ..) = store
    let next = SessionCommit(id: "first", parent: None, messages: [User("one")])
    let assert Ok(first) = commit(next)
    let assert Ok(second) = commit(next)

    assert second == first
    assert memory.snapshot(handle) == first
  })
}

pub fn duplicate_id_with_different_contents_is_corrupt_test() {
  check(Session(head: None, messages: []), fn(store, handle) {
    let SessionStore(commit:, ..) = store
    let assert Ok(first) =
      commit(SessionCommit(id: "first", parent: None, messages: [User("one")]))
    let assert Error(Corrupt(_)) =
      commit(
        SessionCommit(id: "first", parent: None, messages: [User("different")]),
      )

    assert memory.snapshot(handle) == first
  })
}

pub fn parent_conflict_leaves_session_unchanged_test() {
  check(
    Session(head: Some("current"), messages: [User("saved")]),
    fn(store, handle) {
      let SessionStore(commit:, ..) = store
      let initial = memory.snapshot(handle)
      let assert Error(ParentConflict(expected: None, actual: Some("current"))) =
        commit(SessionCommit(id: "next", parent: None, messages: [User("new")]))

      assert memory.snapshot(handle) == initial
    },
  )
}

pub fn empty_commit_is_invalid_and_leaves_session_unchanged_test() {
  check(Session(head: None, messages: []), fn(store, handle) {
    let SessionStore(commit:, ..) = store
    let initial = memory.snapshot(handle)
    let assert Error(InvalidCommit(_)) =
      commit(SessionCommit(id: "empty", parent: None, messages: []))

    assert memory.snapshot(handle) == initial
  })
}
