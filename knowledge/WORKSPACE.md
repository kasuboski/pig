# Workspace Design

A persistent workspace for pig agents, backed by SQLite. Agents get a sandboxed virtual filesystem and a key-value memory store that survive across sessions.

Agent-owned inference settings are durable state too. Restoring an agent/session
restores the setting used for subsequent `InferenceRequest` values. A mid-session
change affects later requests and emits the normal setting and inference events;
it is not a per-run override.

Based on the [AgentFS spec](https://github.com/tursodatabase/agentfs/blob/main/SPEC.md) v0.4, stripped down to what pig needs.

## Overview

Agents currently have no persistence. Every `pig.run()` starts from scratch. The workspace gives agents:

1. **A virtual filesystem** — create, read, list, and delete files in a SQLite-backed directory tree. Agents treat these as normal file operations.
2. **A key-value memory** — store and retrieve values across conversations. Framed as "remember" and "recall" so the LLM thinks of it as memory.

The workspace is a single SQLite database. One file, zero config.

---

## Dependencies

- [`sqlight`](https://hexdocs.pm/sqlight/) (v1.1.0+) — Gleam bindings for SQLite via the `esqlite3` NIF

---

## The `Workspace` Type

```gleam
// In src/pig/workspace.gleam
pub opaque type Workspace {
  Workspace(connection: sqlight.Connection)
}
```

`sqlight.Connection` is wrapped in an opaque type. Users never import or touch `sqlight` directly.

**Why wrap it:**
- sqlight becomes an implementation detail — if we swap SQLite libraries later, no API break
- `Workspace` is a distinct type — can't accidentally pass a raw connection from elsewhere
- Room to grow — `chunk_size`, `schema_version`, etc. can be added without changing the API
- Controlled surface — users call `workspace.read_file(ws, path)`, not raw SQL

**Escape hatch** for power users who need raw SQL:
```gleam
pub fn connection(ws: Workspace) -> sqlight.Connection
```

---

## API Surface

One pattern: **open → construct tools → register**. No pig core changes needed.

```gleam
let assert Ok(ws) = workspace.open("./agent.db")

let cfg =
  pig.new(my_provider)
  |> pig.with_tools(workspace.all_tools(ws))
  |> pig.with_system_prompt("You are a helpful assistant.")
```

Or register individual tools to pick and choose:

```gleam
let assert Ok(ws) = workspace.open("./agent.db")

let cfg =
  pig.new(my_provider)
  |> pig.with_tool(workspace.read_file(ws))
  |> pig.with_tool(workspace.write_file(ws))
  // skip the rest — just read and write
```

Or mix workspace tools with custom tools that share the same DB:

```gleam
let assert Ok(ws) = workspace.open("./agent.db")

let cfg =
  pig.new(my_provider)
  |> pig.with_tools(workspace.all_tools(ws))
  |> pig.with_tool(my_custom_tool(ws))
```

A custom tool accepts a `Workspace` and closes over it:

```gleam
pub fn my_custom_tool(ws: workspace.Workspace) -> tool.Tool {
  tool.Tool(
    definition: ...,
    handler: fn(args) {
      let assert Ok(content) = workspace.read_file(ws, "/notes.txt")
      // do something with content
      Ok(json.string("done"))
    },
  )
}
```

### Workspace Lifecycle

```gleam
pub fn open(path: String) -> Result(Workspace, workspace.Error)
pub fn close(ws: Workspace) -> Result(Nil, workspace.Error)
```

`open` creates the DB if it doesn't exist, runs schema initialization, enables WAL mode. Returns `Error` immediately if anything fails — no lazy opening, no deferred errors.

### Pig Core Addition

One small addition to `src/pig.gleam`:

```gleam
pub fn with_tools(config: PigConfig, tools: List(tool.Tool)) -> PigConfig {
  list.fold(tools, config, with_tool)
}
```

Not workspace-specific — useful any time you have a batch of tools. Workspace provides `workspace.all_tools(ws) -> List(Tool)` as a convenience.

---

## Concurrency

Each agent gets its own SQLite database. There is no cross-agent contention.

Within a single agent, pig's `parallel.gleam` may spawn multiple tool calls concurrently. SQLite's serialized mode (`SQLITE_THREADSAFE=1`) handles this — it acquires an internal mutex per connection, so concurrent calls are safe. WAL mode (enabled on init) means readers never block writers and writers never block readers.

This is sufficient for agent workloads. No OTP actor wrapping needed.

---

## Tool Definitions

### File Tools

| Tool | Parameters | Description |
|------|------------|-------------|
| `read_file` | `{path: String, offset?: Int, limit?: Int}` | Read file contents with line numbers |
| `write_file` | `{path: String, content: String}` | Create or replace a file with the given content |
| `list_directory` | `{path: String}` | List all entries in a directory |
| `delete_file` | `{path: String}` | Delete a file or empty directory |

### Memory Tools

| Tool | Parameters | Description |
|------|------------|-------------|
| `remember` | `{key: String, value: String}` | Store a value that persists across conversations |
| `recall` | `{key: String}` | Retrieve a previously stored value by key |
| `list_keys` | `{prefix: String}` | List all stored keys matching a prefix |

### `read_file` Details

The `read_file` tool always returns line-numbered output, even for full-file reads:

```
0\tfn main() {
1\t  let name = "pig"
2\t  io.println("Hello, " <> name)
3\t}
```

Format: `"N\tline_content"` (tab-separated line number and content). Lines are 0-indexed.

Parameters:
- `path` (required) — absolute path in workspace
- `offset` (optional, default 0) — start line, 0-indexed
- `limit` (optional, default all) — max lines to return

This lets LLMs read slices of large files without burning tokens on the whole file. An agent working with a 500-line file can read lines 200-210 with `offset: 200, limit: 10`.

Implementation: read full content from SQLite chunks, split by `\n`, slice with offset/limit, prepend line numbers. For agent artifact sizes (sub-MB text files), this is fine.

### Tool Naming

No implementation prefixes. The LLM sees `read_file`, not `vfs_read_file`. These are just file operations and memory operations.

The names `recall`/`remember` frame the KV store as the agent's memory. The LLM naturally understands "remember this for later" and "recall what I told you about X."

---

## Schema

A pig-specific subset of the AgentFS v0.4 spec. No POSIX extras (no permissions, symlinks, hard links, device files, nanosecond timestamps).

```sql
-- File metadata
CREATE TABLE IF NOT EXISTS vfs_inode (
  ino INTEGER PRIMARY KEY AUTOINCREMENT,
  mode INTEGER NOT NULL,
  size INTEGER NOT NULL DEFAULT 0,
  mtime INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_vfs_inode_mtime ON vfs_inode(mtime);

-- Directory tree
CREATE TABLE IF NOT EXISTS vfs_dentry (
  name TEXT NOT NULL,
  parent_ino INTEGER NOT NULL,
  ino INTEGER NOT NULL,
  UNIQUE(parent_ino, name)
);

CREATE INDEX IF NOT EXISTS idx_vfs_dentry_parent
  ON vfs_dentry(parent_ino, name);

-- File content (chunked)
CREATE TABLE IF NOT EXISTS vfs_data (
  ino INTEGER NOT NULL,
  chunk_index INTEGER NOT NULL,
  data BLOB NOT NULL,
  PRIMARY KEY (ino, chunk_index)
);

-- Key-value memory
CREATE TABLE IF NOT EXISTS kv_store (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE INDEX IF NOT EXISTS idx_kv_store_updated
  ON kv_store(updated_at);
```

### Initialization

Run on first open:

```sql
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;

INSERT OR IGNORE INTO vfs_inode (ino, mode, size, mtime)
  VALUES (1, 16877, 0, unixepoch());
```

Mode constants:
- `16877` = `0o040755` (directory with rwxr-xr-x)
- `33188` = `0o100644` (regular file with rw-r--r--)

### Chunk Size

Default 4096 bytes, matching the AgentFS spec. For agent workloads (text files, code), this is reasonable. Can be tuned later if profiling shows otherwise.

---

## Module Layout

```
src/pig/workspace.gleam          — Public API: Workspace type, open, close, tool constructors, all_tools
src/pig/workspace/schema.gleam   — SQL schema initialization
src/pig/workspace/vfs.gleam      — VFS operations: read, write, list, delete, mkdir
src/pig/workspace/kv.gleam       — KV operations: get, set, delete, list_keys
src/pig/workspace/tools.gleam    — Tool constructors (closures over Workspace)
```

`pig/workspace` is the module name. "Workspace" is what the user thinks about — "my agent has a workspace." Not `agentfs` (coupled to a spec name we're taking a subset of).

---

## VFS Operations

### Path Resolution

Resolve a path string to an inode number:

1. Start at root inode (ino=1)
2. Split path by `/`, filter empty components
3. For each component: `SELECT ino FROM vfs_dentry WHERE parent_ino = ? AND name = ?`
4. Return final inode or error if not found

### `write_file(ws, path, content)`

1. Resolve parent directory path to inode
2. Check if file already exists at that path
3. If exists: delete old data chunks, update inode
4. If new: insert inode, insert dentry
5. Split content into chunks, insert into `vfs_data`
6. Update inode size and mtime
7. All steps wrapped in a transaction

### `read_file(ws, path)`

1. Resolve path to inode
2. Fetch all chunks: `SELECT data FROM vfs_data WHERE ino = ? ORDER BY chunk_index ASC`
3. Concatenate chunks
4. Return raw content string

### `list_directory(ws, path)`

1. Resolve path to inode
2. `SELECT name FROM vfs_dentry WHERE parent_ino = ? ORDER BY name ASC`
3. Return entry names

### `delete_file(ws, path)`

1. Resolve path to inode and parent
2. If directory: check it's empty (no dentries with this inode as parent)
3. Delete dentry, delete data chunks, delete inode
4. All steps wrapped in a transaction

### `mkdir(ws, path)`

1. Resolve parent directory
2. Insert inode with directory mode
3. Insert dentry

---

## KV Operations

### `remember(ws, key, value)`

```sql
INSERT INTO kv_store (key, value, updated_at)
VALUES (?, ?, unixepoch())
ON CONFLICT(key) DO UPDATE SET
  value = excluded.value,
  updated_at = unixepoch()
```

### `recall(ws, key)`

```sql
SELECT value FROM kv_store WHERE key = ?
```

### `list_keys(ws, prefix)`

```sql
SELECT key FROM kv_store
WHERE key LIKE ? || '%'
ORDER BY key ASC
```

---

## Not Building (Yet)

These can be added incrementally:

- **Overlay filesystem** — whiteouts, copy-on-write, origin tracking
- **POSIX permissions** — mode bits, uid/gid
- **Symlinks and hard links**
- **Append to file** — `append_file(path, content)`
- **Rename/move** — `rename(path, new_path)`
- **File stat/metadata** — `stat(path)` returning size, mtime, type
- **Tool audit trail** — pig already has this via SessionEvents

---

## Open Questions

1. **`RETURNING` clause** — Does `sqlight.query` support `INSERT ... RETURNING`? If not, use `sqlight.exec` for the insert then a separate `sqlight.query` to fetch by rowid. Alternative: `SELECT last_insert_rowid()` after the insert.

2. **Transaction wrapping** — Multi-step VFS ops (create file = insert inode + dentry + chunks) need atomicity. `sqlight` has no explicit transaction API. Can we use `sqlight.exec("BEGIN")` / `sqlight.exec("COMMIT")`? Need a spike to verify.

3. **Chunk size** — The spec says 4096 bytes. For agent artifacts (text, code), larger chunks (16KB+) might reduce overhead. Needs profiling.

---

## sqlight API Reference

The `sqlight` package (v1.1.0) provides:

```gleam
// Types
pub type Connection   // opaque, wraps esqlite3 connection
pub type Value        // query parameter values
pub type Error        // {SqlightError, ErrorCode, String, Int}

// Connection lifecycle
pub fn open(path: String) -> Result(Connection, Error)
pub fn close(connection: Connection) -> Result(Nil, Error)
pub fn with_connection(path: String, f: fn(Connection) -> a) -> a

// Queries
pub fn exec(sql: String, on connection: Connection) -> Result(Nil, Error)
pub fn query(
  sql: String,
  on connection: Connection,
  with arguments: List(Value),
  expecting decoder: decode.Decoder(t),
) -> Result(List(t), Error)

// Value constructors
pub fn text(value: String) -> Value
pub fn int(value: Int) -> Value
pub fn float(value: Float) -> Value
pub fn bool(value: Bool) -> Value
pub fn blob(value: BitArray) -> Value
pub fn null() -> Value
pub fn nullable(inner_type: fn(t) -> Value, value: Option(t)) -> Value
```

Key notes:
- `query` runs a single SQL statement and decodes results eagerly into `List(t)`
- `exec` runs one or more SQL statements without returning results
- `query` only executes the first statement in the SQL string; others are discarded
- No explicit transaction API — use `exec("BEGIN")` / `exec("COMMIT")`
