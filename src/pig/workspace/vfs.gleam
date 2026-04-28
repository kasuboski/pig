//// Virtual filesystem operations for pig workspace.
////
//// File and directory operations backed by SQLite tables:
//// - `vfs_inode` — file metadata (mode, size, mtime)
//// - `vfs_dentry` — directory tree (name -> inode mapping)
//// - `vfs_data` — file content (chunked blobs)

import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import sqlight

/// Errors from VFS operations.
pub type Error {
  SqlError(sqlight.Error)
  NotFound(path: String)
  NotEmpty(path: String)
  AlreadyExists(path: String)
  InvalidPath(path: String)
}

const dir_mode = 16877
const file_mode = 33188
const chunk_size = 4096

// ── Path helpers ─────────────────────────────────────────────────

fn split_path(path: String) -> List(String) {
  path
  |> string.split("/")
  |> list.filter(fn(s) { s != "" })
}

/// Validate path doesn't contain . or .. components.
fn validate_path(path: String) -> Result(Nil, Error) {
  case string.contains(path, "..") || string.contains(path, "/./") {
    True -> Error(InvalidPath(path: path))
    False -> Ok(Nil)
  }
}

/// Resolve full path → inode. Root (/) = ino 1.
fn resolve_path(
  conn: sqlight.Connection,
  path: String,
) -> Result(Int, Error) {
  use Nil <- result.try(validate_path(path))
  case split_path(path) {
    [] -> Ok(1)
    components -> walk_path(conn, components, 1, path)
  }
}

fn walk_path(
  conn: sqlight.Connection,
  components: List(String),
  current_ino: Int,
  original_path: String,
) -> Result(Int, Error) {
  case components {
    [] -> Ok(current_ino)
    [name, ..rest] ->
      sqlight.query(
        "SELECT ino FROM vfs_dentry WHERE parent_ino = ? AND name = ?",
        on: conn,
        with: [sqlight.int(current_ino), sqlight.text(name)],
        expecting: decode.at([0], decode.int),
      )
      |> result.map_error(SqlError)
      |> result.try(fn(ino) {
        case ino {
          [id] -> walk_path(conn, rest, id, original_path)
          _ -> Error(NotFound(path: original_path))
        }
      })
  }
}

/// Resolve all but the last component → #(parent_ino, filename).
fn resolve_parent(
  conn: sqlight.Connection,
  path: String,
) -> Result(#(Int, String), Error) {
  use Nil <- result.try(validate_path(path))
  let components = split_path(path)
  case components {
    [] -> Error(InvalidPath(path: path))
    _ -> {
      let assert Ok(filename) = list.last(components)
      let parent_components =
        list.take(components, list.length(components) - 1)
      case parent_components {
        [] -> Ok(#(1, filename))
        _ -> {
          let parent_path = "/" <> string.join(parent_components, "/")
          use parent_ino <- result.try(resolve_path(conn, parent_path))
          Ok(#(parent_ino, filename))
        }
      }
    }
  }
}

// ── Inode helpers ────────────────────────────────────────────────

/// Insert inode, return its ino via RETURNING.
fn insert_inode(
  conn: sqlight.Connection,
  mode: Int,
) -> Result(Int, Error) {
  sqlight.query(
    "INSERT INTO vfs_inode (mode, size, mtime) VALUES (?, 0, unixepoch()) RETURNING ino",
    on: conn,
    with: [sqlight.int(mode)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(SqlError)
  |> result.try(fn(rows) {
    case rows {
      [ino] -> Ok(ino)
      _ ->
        Error(SqlError(sqlight.SqlightError(
          code: sqlight.Internal,
          message: "unexpected RETURNING result",
          offset: -1,
        )))
    }
  })
}

/// Insert dentry row.
fn insert_dentry(
  conn: sqlight.Connection,
  name: String,
  parent_ino: Int,
  ino: Int,
) -> Result(Nil, Error) {
  sqlight.query(
    "INSERT INTO vfs_dentry (name, parent_ino, ino) VALUES (?, ?, ?) RETURNING ino",
    on: conn,
    with: [sqlight.text(name), sqlight.int(parent_ino), sqlight.int(ino)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(SqlError)
  |> result.map(fn(_) { Nil })
}

/// Look up inode for a name in a parent directory.
fn lookup_dentry(
  conn: sqlight.Connection,
  parent_ino: Int,
  name: String,
) -> Result(Int, Error) {
  sqlight.query(
    "SELECT ino FROM vfs_dentry WHERE parent_ino = ? AND name = ?",
    on: conn,
    with: [sqlight.int(parent_ino), sqlight.text(name)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(SqlError)
  |> result.try(fn(rows) {
    case rows {
      [ino] -> Ok(ino)
      _ -> Error(NotFound(path: name))
    }
  })
}

// ── Transaction helper ───────────────────────────────────────────

/// Run a function inside a transaction. Commits on Ok, rolls back on Error.
fn transaction(
  conn: sqlight.Connection,
  body: fn() -> Result(a, Error),
) -> Result(a, Error) {
  use Nil <- result.try(
    sqlight.exec("BEGIN", on: conn) |> result.map_error(SqlError),
  )
  case body() {
    Ok(value) ->
      sqlight.exec("COMMIT", on: conn)
      |> result.map_error(SqlError)
      |> result.map(fn(_) { value })
    Error(e) -> {
      let _ = sqlight.exec("ROLLBACK", on: conn)
      Error(e)
    }
  }
}

// ── Chunk helpers ────────────────────────────────────────────────

/// Insert file content as chunks. Tail-recursive.
fn insert_chunks(
  conn: sqlight.Connection,
  ino: Int,
  remaining: BitArray,
  index: Int,
) -> Result(Nil, Error) {
  insert_chunks_loop(conn, ino, remaining, index)
}

fn insert_chunks_loop(
  conn: sqlight.Connection,
  ino: Int,
  remaining: BitArray,
  index: Int,
) -> Result(Nil, Error) {
  let remaining_size = bit_array.byte_size(remaining)
  case remaining_size {
    0 -> Ok(Nil)
    _ if remaining_size <= chunk_size ->
      insert_one_chunk(conn, ino, remaining, index)
    _ -> {
      let assert Ok(chunk) = bit_array.slice(remaining, 0, chunk_size)
      let assert Ok(rest) =
        bit_array.slice(remaining, chunk_size, remaining_size - chunk_size)
      case insert_one_chunk(conn, ino, chunk, index) {
        Ok(Nil) -> insert_chunks_loop(conn, ino, rest, index + 1)
        Error(e) -> Error(e)
      }
    }
  }
}

fn insert_one_chunk(
  conn: sqlight.Connection,
  ino: Int,
  data: BitArray,
  index: Int,
) -> Result(Nil, Error) {
  sqlight.query(
    "INSERT INTO vfs_data (ino, chunk_index, data) VALUES (?, ?, ?) RETURNING chunk_index",
    on: conn,
    with: [sqlight.int(ino), sqlight.int(index), sqlight.blob(data)],
    expecting: decode.at([0], decode.int),
  )
  |> result.map_error(SqlError)
  |> result.map(fn(_) { Nil })
}

// ── Public API ───────────────────────────────────────────────────

/// Create a directory at the given path.
pub fn mkdir(
  conn: sqlight.Connection,
  path: String,
) -> Result(Nil, Error) {
  use #(parent_ino, dir_name) <- result.try(resolve_parent(conn, path))

  case lookup_dentry(conn, parent_ino, dir_name) {
    Ok(_) -> Error(AlreadyExists(path: path))
    Error(NotFound(_)) -> {
      use Nil <- result.try(transaction(conn, fn() {
        use new_ino <- result.try(insert_inode(conn, dir_mode))
        insert_dentry(conn, dir_name, parent_ino, new_ino)
      }))
      Ok(Nil)
    }
    Error(e) -> Error(e)
  }
}

/// Write content to a file. Creates if missing, overwrites if exists.
pub fn write_file(
  conn: sqlight.Connection,
  path: String,
  content: String,
) -> Result(Nil, Error) {
  use #(parent_ino, filename) <- result.try(resolve_parent(conn, path))

  use Nil <- result.try(transaction(conn, fn() {
    // Get or create the inode
    use ino <- result.try(
      case lookup_dentry(conn, parent_ino, filename) {
        // Existing file — clear old chunks
        Ok(existing_ino) -> {
          use Nil <- result.try(
            sqlight.exec(
              "DELETE FROM vfs_data WHERE ino = " <> int.to_string(existing_ino),
              on: conn,
            )
            |> result.map_error(SqlError),
          )
          Ok(existing_ino)
        }
        // New file
        Error(NotFound(_)) -> {
          use new_ino <- result.try(insert_inode(conn, file_mode))
          use Nil <- result.try(insert_dentry(conn, filename, parent_ino, new_ino))
          Ok(new_ino)
        }
        Error(e) -> Error(e)
      },
    )

    // Update size and mtime
    let bytes = <<content:utf8>>
    let byte_size = bit_array.byte_size(bytes)
    use Nil <- result.try(
      sqlight.exec(
        "UPDATE vfs_inode SET size = "
          <> int.to_string(byte_size)
          <> ", mtime = unixepoch() WHERE ino = "
          <> int.to_string(ino),
        on: conn,
      )
      |> result.map_error(SqlError),
    )

    insert_chunks(conn, ino, bytes, 0)
  }))

  Ok(Nil)
}

/// Read the full content of a file.
pub fn read_file(
  conn: sqlight.Connection,
  path: String,
) -> Result(String, Error) {
  use ino <- result.try(resolve_path(conn, path))

  use _ <- result.try(
    sqlight.query(
      "SELECT mode FROM vfs_inode WHERE ino = ?",
      on: conn,
      with: [sqlight.int(ino)],
      expecting: decode.at([0], decode.int),
    )
    |> result.map_error(SqlError)
    |> result.try(fn(rows) {
      case rows {
        [] -> Error(NotFound(path: path))
        [m] if m == dir_mode -> Error(InvalidPath(path: path))
        [_m] -> Ok(Nil)
        _ -> Error(NotFound(path: path))
      }
    }),
  )

  sqlight.query(
    "SELECT data FROM vfs_data WHERE ino = ? ORDER BY chunk_index ASC",
    on: conn,
    with: [sqlight.int(ino)],
    expecting: decode.at([0], decode.bit_array),
  )
  |> result.map_error(SqlError)
  |> result.try(fn(chunks) {
    case chunks {
      [] -> Ok("")
      _ -> {
        let combined = bit_array.concat(chunks)
        case bit_array.to_string(combined) {
          Ok(content) -> Ok(content)
          Error(_) ->
            Error(SqlError(sqlight.SqlightError(
              code: sqlight.Internal,
              message: "failed to convert blob to string",
              offset: -1,
            )))
        }
      }
    }
  })
}

/// Read lines with offset/limit, formatted as "N\\tline_content" (0-indexed).
pub fn read_file_lines(
  conn: sqlight.Connection,
  path: String,
  offset: Int,
  limit: Int,
) -> Result(String, Error) {
  use content <- result.try(read_file(conn, path))
  let lines =
    content
    |> string.split("\n")
    |> list.drop(offset)
    |> list.take(limit)
    |> list.index_map(fn(line, index) {
      int.to_string(offset + index) <> "\t" <> line
    })
  Ok(string.join(lines, "\n"))
}

/// List entries in a directory, sorted alphabetically.
pub fn list_directory(
  conn: sqlight.Connection,
  path: String,
) -> Result(List(String), Error) {
  use ino <- result.try(resolve_path(conn, path))

  // Verify the target is actually a directory
  use _ <- result.try(
    sqlight.query(
      "SELECT mode FROM vfs_inode WHERE ino = ?",
      on: conn,
      with: [sqlight.int(ino)],
      expecting: decode.at([0], decode.int),
    )
    |> result.map_error(SqlError)
    |> result.try(fn(rows) {
      case rows {
        [m] if m == dir_mode -> Ok(Nil)
        [_] -> Error(InvalidPath(path: path))
        _ -> Error(NotFound(path: path))
      }
    }),
  )

  sqlight.query(
    "SELECT name FROM vfs_dentry WHERE parent_ino = ? ORDER BY name ASC",
    on: conn,
    with: [sqlight.int(ino)],
    expecting: decode.at([0], decode.string),
  )
  |> result.map_error(SqlError)
}

/// Delete a file or empty directory.
pub fn delete_file(
  conn: sqlight.Connection,
  path: String,
) -> Result(Nil, Error) {
  use ino <- result.try(resolve_path(conn, path))
  use #(parent_ino, filename) <- result.try(resolve_parent(conn, path))

  // Check if directory and if so, whether it's empty
  use mode <- result.try(
    sqlight.query(
      "SELECT mode FROM vfs_inode WHERE ino = ?",
      on: conn,
      with: [sqlight.int(ino)],
      expecting: decode.at([0], decode.int),
    )
    |> result.map_error(SqlError)
    |> result.try(fn(rows) {
      case rows {
        [] -> Error(NotFound(path: path))
        [mode] -> Ok(mode)
        _ -> Error(NotFound(path: path))
      }
    }),
  )

  use Nil <- result.try(case mode == dir_mode {
    True -> {
      use Nil <- result.try(
        sqlight.query(
          "SELECT COUNT(*) FROM vfs_dentry WHERE parent_ino = ?",
          on: conn,
          with: [sqlight.int(ino)],
          expecting: decode.at([0], decode.int),
        )
        |> result.map_error(SqlError)
        |> result.try(fn(rows) {
          case rows {
            [0] -> Ok(Nil)
            _ -> Error(NotEmpty(path: path))
          }
        }),
      )
      Ok(Nil)
    }
    False -> Ok(Nil)
  })

  transaction(conn, fn() {
    // Use parameterized query to avoid SQL injection on filename
    use Nil <- result.try(
      sqlight.query(
        "DELETE FROM vfs_dentry WHERE parent_ino = ? AND name = ? RETURNING name",
        on: conn,
        with: [sqlight.int(parent_ino), sqlight.text(filename)],
        expecting: decode.at([0], decode.string),
      )
      |> result.map_error(SqlError)
      |> result.map(fn(_) { Nil }),
    )
    // Propagate errors to trigger transaction rollback
    use Nil <- result.try(
      sqlight.exec(
        "DELETE FROM vfs_data WHERE ino = " <> int.to_string(ino),
        on: conn,
      )
      |> result.map_error(SqlError),
    )
    use Nil <- result.try(
      sqlight.exec(
        "DELETE FROM vfs_inode WHERE ino = " <> int.to_string(ino),
        on: conn,
      )
      |> result.map_error(SqlError),
    )
    Ok(Nil)
  })
}
