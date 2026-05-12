//// Key-value store tests for pig workspace.

import gleeunit
import gleeunit/should
import pig/workspace/kv
import pig/workspace/schema
import sqlight

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Test helpers ────────────────────────────────────────────────────

/// Helper function to run a test with a fresh in-memory database.
fn with_db(f: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(Nil) = schema.init(conn)
  let result = f(conn)
  let assert Ok(Nil) = sqlight.close(conn)
  result
}

// ── Tests ────────────────────────────────────────────────────────────

/// Store a value, recall it, assert equal
pub fn remember_stores_value_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = kv.remember(conn, "test_key", "test_value")
    let assert Ok(value) = kv.recall(conn, "test_key")
    should.equal(value, "test_value")
  })
}

/// Recall nonexistent key returns Error(NotFound)
pub fn recall_missing_key_returns_error_test() {
  with_db(fn(conn) {
    let assert Error(kv.NotFound(key: "missing_key")) =
      kv.recall(conn, "missing_key")
  })
}

/// Store value A, store value B with same key, recall returns B
pub fn remember_overwrites_existing_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = kv.remember(conn, "my_key", "value_a")
    let assert Ok(Nil) = kv.remember(conn, "my_key", "value_b")
    let assert Ok(value) = kv.recall(conn, "my_key")
    should.equal(value, "value_b")
  })
}

/// Store keys "user:name", "user:email", "config:theme", list_keys("user:") returns ["user:email", "user:name"]
pub fn list_keys_returns_matching_prefix_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = kv.remember(conn, "user:name", "john")
    let assert Ok(Nil) = kv.remember(conn, "user:email", "john@example.com")
    let assert Ok(Nil) = kv.remember(conn, "config:theme", "dark")

    let assert Ok(keys) = kv.list_keys(conn, "user:")
    should.equal(keys, ["user:email", "user:name"])
  })
}

/// List all keys with empty prefix
pub fn list_keys_empty_prefix_returns_all_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = kv.remember(conn, "alpha", "1")
    let assert Ok(Nil) = kv.remember(conn, "beta", "2")
    let assert Ok(Nil) = kv.remember(conn, "gamma", "3")

    let assert Ok(keys) = kv.list_keys(conn, "")
    should.equal(keys, ["alpha", "beta", "gamma"])
  })
}

/// Keys are in alphabetical order
pub fn list_keys_returns_sorted_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = kv.remember(conn, "zebra", "1")
    let assert Ok(Nil) = kv.remember(conn, "apple", "2")
    let assert Ok(Nil) = kv.remember(conn, "banana", "3")

    let assert Ok(keys) = kv.list_keys(conn, "")
    should.equal(keys, ["apple", "banana", "zebra"])
  })
}

/// No matching keys returns empty list
pub fn list_keys_no_matches_returns_empty_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = kv.remember(conn, "user:name", "john")
    let assert Ok(Nil) = kv.remember(conn, "config:theme", "dark")

    let assert Ok(keys) = kv.list_keys(conn, "nonexistent:")
    should.equal(keys, [])
  })
}
