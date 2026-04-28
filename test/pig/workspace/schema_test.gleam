//// Schema initialization tests for pig workspace.

import gleam/dynamic/decode
import gleeunit
import gleeunit/should
import pig/workspace/schema
import sqlight

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Test helpers ────────────────────────────────────────────────────

/// Helper function to run a test with a fresh in-memory database.
fn with_db(f: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = sqlight.open(":memory:")
  let result = f(conn)
  let assert Ok(Nil) = sqlight.close(conn)
  result
}

// ── Tests ────────────────────────────────────────────────────────────

/// After init, all four tables exist.
pub fn init_creates_tables_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = schema.init(conn)

    let assert Ok([count]) =
      sqlight.query(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('vfs_inode','vfs_dentry','vfs_data','kv_store')",
        on: conn,
        with: [],
        expecting: decode.at([0], decode.int),
      )

    should.equal(count, 4)
  })
}

/// After init, root inode (ino=1) exists with correct mode and size.
pub fn init_creates_root_inode_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = schema.init(conn)

    let assert Ok([row]) =
      sqlight.query(
        "SELECT ino, mode, size FROM vfs_inode WHERE ino = 1",
        on: conn,
        with: [],
        expecting: decode.dynamic,
      )

    let assert Ok(ino) = decode.run(row, decode.at([0], decode.int))
    let assert Ok(mode) = decode.run(row, decode.at([1], decode.int))
    let assert Ok(size) = decode.run(row, decode.at([2], decode.int))

    should.equal(ino, 1)
    should.equal(mode, 16877)
    should.equal(size, 0)
  })
}

/// Calling init twice doesn't error. Root inode still has ino=1.
pub fn init_is_idempotent_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = schema.init(conn)
    let assert Ok(Nil) = schema.init(conn)

    let assert Ok([row]) =
      sqlight.query(
        "SELECT ino, mode FROM vfs_inode WHERE ino = 1",
        on: conn,
        with: [],
        expecting: decode.dynamic,
      )

    let assert Ok(ino) = decode.run(row, decode.at([0], decode.int))
    let assert Ok(mode) = decode.run(row, decode.at([1], decode.int))

    should.equal(ino, 1)
    should.equal(mode, 16877)
  })
}

/// After init, PRAGMA journal_mode returns "wal" (or "memory" for in-memory DBs).
pub fn init_enables_wal_mode_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = schema.init(conn)

    let assert Ok([mode]) =
      sqlight.query(
        "PRAGMA journal_mode",
        on: conn,
        with: [],
        expecting: decode.at([0], decode.string),
      )

    should.be_true(mode == "wal" || mode == "memory")
  })
}
