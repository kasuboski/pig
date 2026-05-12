//// Schema initialization for pig workspace.

import sqlight

/// Initialize the database schema for the pig workspace.
///
/// This function creates all necessary tables and indexes for the
/// virtual filesystem and key-value store. It is idempotent, meaning
/// it can be called multiple times without error.
///
/// # Pragmas
/// - Sets WAL mode for better concurrency
/// - Sets busy timeout to 5 seconds
///
/// # Tables Created
/// - `vfs_inode`: File inode metadata
/// - `vfs_dentry`: Directory entries (name -> inode mapping)
/// - `vfs_data`: File data chunks
/// - `kv_store`: Key-value storage
///
/// # Root Directory
/// Creates the root directory inode (ino=1, mode=16877) if it doesn't exist.
pub fn init(conn: sqlight.Connection) -> Result(Nil, sqlight.Error) {
  let schema_sql =
    "
PRAGMA journal_mode = WAL;
PRAGMA busy_timeout = 5000;

CREATE TABLE IF NOT EXISTS vfs_inode (
  ino INTEGER PRIMARY KEY AUTOINCREMENT,
  mode INTEGER NOT NULL,
  size INTEGER NOT NULL DEFAULT 0,
  mtime INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_vfs_inode_mtime ON vfs_inode(mtime);

CREATE TABLE IF NOT EXISTS vfs_dentry (
  name TEXT NOT NULL,
  parent_ino INTEGER NOT NULL,
  ino INTEGER NOT NULL,
  UNIQUE(parent_ino, name)
);

CREATE INDEX IF NOT EXISTS idx_vfs_dentry_parent
  ON vfs_dentry(parent_ino, name);

CREATE TABLE IF NOT EXISTS vfs_data (
  ino INTEGER NOT NULL,
  chunk_index INTEGER NOT NULL,
  data BLOB NOT NULL,
  PRIMARY KEY (ino, chunk_index)
);

CREATE TABLE IF NOT EXISTS kv_store (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  created_at INTEGER NOT NULL DEFAULT (unixepoch()),
  updated_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE INDEX IF NOT EXISTS idx_kv_store_updated
  ON kv_store(updated_at);

INSERT OR IGNORE INTO vfs_inode (ino, mode, size, mtime)
  VALUES (1, 16877, 0, unixepoch());
"

  sqlight.exec(schema_sql, on: conn)
}
