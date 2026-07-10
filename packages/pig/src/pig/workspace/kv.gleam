//// Key-value store operations for pig workspace.

import gleam/dynamic/decode
import gleam/result
import gleam/string
import sqlight

/// Custom error type for key-value operations.
pub type Error {
  SqlError(sqlight.Error)
  NotFound(key: String)
}

/// Store a key-value pair, updating the value if the key already exists.
///
/// Uses an upsert operation (INSERT ... ON CONFLICT DO UPDATE) to handle
/// both new keys and updates to existing keys atomically.
///
/// # Example
/// ```gleam
/// let assert Ok(Nil) = kv.remember(conn, "user:1", "Alice")
/// let assert Ok(Nil) = kv.remember(conn, "user:1", "Alice Smith")  // Updates
/// ```
pub fn remember(
  conn: sqlight.Connection,
  key: String,
  value: String,
) -> Result(Nil, Error) {
  let sql =
    "
INSERT INTO kv_store (key, value, updated_at)
VALUES (?, ?, unixepoch())
ON CONFLICT(key) DO UPDATE SET
  value = excluded.value,
  updated_at = unixepoch()
RETURNING key
"

  sqlight.query(
    sql,
    on: conn,
    with: [sqlight.text(key), sqlight.text(value)],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(SqlError)
  |> result.map(fn(_) { Nil })
}

/// Retrieve a value by key.
///
/// Returns an error if the key doesn't exist.
///
/// # Example
/// ```gleam
/// case kv.recall(conn, "user:1") {
///   Ok(name) -> io.println("Found: " <> name)
///   Error(kv.NotFound(key)) -> io.println("Key not found: " <> key)
///   Error(_) -> io.println("Database error")
/// }
/// ```
pub fn recall(conn: sqlight.Connection, key: String) -> Result(String, Error) {
  let sql = "SELECT value FROM kv_store WHERE key = ?"

  sqlight.query(
    sql,
    on: conn,
    with: [sqlight.text(key)],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(SqlError)
  |> result.try(fn(rows) {
    case rows {
      [value] -> Ok(value)
      _ -> Error(NotFound(key: key))
    }
  })
}

/// List all keys that start with the given prefix, sorted alphabetically.
///
/// Escapes SQL LIKE wildcards in the prefix so they match literally.
pub fn list_keys(
  conn: sqlight.Connection,
  prefix: String,
) -> Result(List(String), Error) {
  let escaped = escape_like(prefix)
  let sql =
    "SELECT key FROM kv_store WHERE key LIKE ? || '%' ESCAPE '\\' ORDER BY key ASC"

  sqlight.query(
    sql,
    on: conn,
    with: [sqlight.text(escaped)],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(SqlError)
}

/// Escape SQL LIKE wildcard characters (%, _, \) so they match literally.
fn escape_like(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("%", "\\%")
  |> string.replace("_", "\\_")
}
