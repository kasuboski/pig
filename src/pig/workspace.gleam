import gleam/result
import pig/tool
import pig/workspace/kv
import pig/workspace/schema
import pig/workspace/tools
import pig/workspace/vfs
import sqlight

/// The Workspace type wraps a SQLite connection.
pub opaque type Workspace {
  Workspace(connection: sqlight.Connection)
}

/// Errors that can occur when working with a workspace.
pub type Error {
  SqlError(sqlight.Error)
  NotFound(path: String)
  NotEmpty(path: String)
  AlreadyExists(path: String)
  InvalidPath(path: String)
  KeyError(key: String)
}

/// Open a workspace database. Creates if doesn't exist.
pub fn open(path: String) -> Result(Workspace, Error) {
  use conn <- result.try(result.map_error(sqlight.open(path), SqlError))
  case schema.init(conn) {
    Ok(Nil) -> Ok(Workspace(conn))
    Error(e) -> {
      let _ = sqlight.close(conn)
      Error(SqlError(e))
    }
  }
}

/// Close the workspace database.
pub fn close(ws: Workspace) -> Result(Nil, Error) {
  sqlight.close(ws.connection)
  |> result.map_error(SqlError)
}

/// Get the underlying connection (escape hatch for power users).
pub fn connection(ws: Workspace) -> sqlight.Connection {
  ws.connection
}

/// Write content to a file.
pub fn write_file(
  ws: Workspace,
  path: String,
  content: String,
) -> Result(Nil, Error) {
  ws.connection
  |> vfs.write_file(path, content)
  |> result.map_error(wrap_vfs_error)
}

/// Read the full content of a file.
pub fn read_file(ws: Workspace, path: String) -> Result(String, Error) {
  ws.connection
  |> vfs.read_file(path)
  |> result.map_error(wrap_vfs_error)
}

/// Read lines with offset/limit, formatted with line numbers.
pub fn read_file_lines(
  ws: Workspace,
  path: String,
  offset: Int,
  limit: Int,
) -> Result(String, Error) {
  ws.connection
  |> vfs.read_file_lines(path, offset, limit)
  |> result.map_error(wrap_vfs_error)
}

/// List entries in a directory.
pub fn list_directory(
  ws: Workspace,
  path: String,
) -> Result(List(String), Error) {
  ws.connection
  |> vfs.list_directory(path)
  |> result.map_error(wrap_vfs_error)
}

/// Create a directory.
pub fn mkdir(ws: Workspace, path: String) -> Result(Nil, Error) {
  ws.connection
  |> vfs.mkdir(path)
  |> result.map_error(wrap_vfs_error)
}

/// Delete a file or empty directory.
pub fn delete_file(ws: Workspace, path: String) -> Result(Nil, Error) {
  ws.connection
  |> vfs.delete_file(path)
  |> result.map_error(wrap_vfs_error)
}

/// Store a key-value pair.
pub fn remember(
  ws: Workspace,
  key: String,
  value: String,
) -> Result(Nil, Error) {
  ws.connection
  |> kv.remember(key, value)
  |> result.map_error(wrap_kv_error)
}

/// Retrieve a value by key.
pub fn recall(ws: Workspace, key: String) -> Result(String, Error) {
  ws.connection
  |> kv.recall(key)
  |> result.map_error(wrap_kv_error)
}

/// List keys matching a prefix.
pub fn list_keys(ws: Workspace, prefix: String) -> Result(List(String), Error) {
  ws.connection
  |> kv.list_keys(prefix)
  |> result.map_error(wrap_kv_error)
}

/// Get all workspace tools as a list.
pub fn all_tools(ws: Workspace) -> List(tool.Tool) {
  tools.all_tools(ws.connection)
}

/// Convert VFS errors to workspace errors.
fn wrap_vfs_error(e: vfs.Error) -> Error {
  case e {
    vfs.SqlError(e) -> SqlError(e)
    vfs.NotFound(p) -> NotFound(p)
    vfs.NotEmpty(p) -> NotEmpty(p)
    vfs.AlreadyExists(p) -> AlreadyExists(p)
    vfs.InvalidPath(p) -> InvalidPath(p)
  }
}

/// Convert KV errors to workspace errors.
fn wrap_kv_error(e: kv.Error) -> Error {
  case e {
    kv.SqlError(e) -> SqlError(e)
    kv.NotFound(k) -> KeyError(k)
  }
}
