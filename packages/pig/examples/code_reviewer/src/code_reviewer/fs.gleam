//// Filesystem loading for the code reviewer.
//// Walks a real directory tree and loads text files into pig's VFS workspace.

import filepath
import gleam/io
import gleam/list
import gleam/set.{type Set}
import pig/workspace/vfs
import simplifile
import sqlight

/// Default entries (directories and files) to skip when loading a repo.
pub fn default_ignore_entries() -> Set(String) {
  set.from_list([
    ".git",
    "node_modules",
    "vendor",
    "build",
    "_build",
    "target",
    ".next",
    "__pycache__",
    ".tox",
    "venv",
    ".venv",
    "dist",
    ".gradle",
    ".idea",
    ".vscode",
    ".DS_Store",
    "coverage",
    ".cache",
    ".turbo",
    "bower_components",
    ".sass-cache",
    ".npm",
    ".yarn",
  ])
}

/// Load all text files from a real directory into the VFS under /repo/.
/// Skips directories in the ignore set and binary/non-UTF-8 files.
/// Returns the count of files loaded.
pub fn load_repo(conn: sqlight.Connection, repo_path: String) -> Int {
  // Create /repo directory
  let _ = vfs.mkdir(conn, "/repo")
  load_dir(conn, repo_path, "/repo", default_ignore_entries())
}

/// Recursive directory walker.
fn load_dir(
  conn: sqlight.Connection,
  real_path: String,
  vfs_path: String,
  ignore: Set(String),
) -> Int {
  case simplifile.read_directory(at: real_path) {
    Ok(entries) ->
      entries
      |> list.fold(0, fn(count, entry) {
        let full_real = filepath.join(real_path, entry)
        let full_vfs = filepath.join(vfs_path, entry)

        case set.contains(ignore, entry) {
          True -> count
          False -> {
            case simplifile.is_directory(full_real) {
              Ok(True) -> {
                // Create VFS directory and recurse
                let _ = vfs.mkdir(conn, full_vfs)
                let sub_count = load_dir(conn, full_real, full_vfs, ignore)
                count + sub_count
              }
              Ok(False) -> {
                // Try to read as text file
                case load_file(conn, full_real, full_vfs) {
                  Ok(Nil) -> count + 1
                  Error(_) -> count
                }
              }
              Error(_) -> {
                // Could not determine if directory, skip entry
                count
              }
            }
          }
        }
      })
    Error(e) -> {
      io.println("⚠ Could not read directory: " <> real_path)
      io.println("  " <> simplifile.describe_error(e))
      0
    }
  }
}

/// Load a single file into the VFS. Skips binary/non-UTF-8 files.
fn load_file(
  conn: sqlight.Connection,
  real_path: String,
  vfs_path: String,
) -> Result(Nil, Nil) {
  case simplifile.read(from: real_path) {
    Ok(content) -> {
      case vfs.write_file(conn, vfs_path, content) {
        Ok(Nil) -> Ok(Nil)
        Error(e) -> {
          io.println(
            "⚠ VFS write error for "
            <> vfs_path
            <> ": "
            <> describe_vfs_error(e),
          )
          Error(Nil)
        }
      }
    }
    Error(simplifile.NotUtf8) -> Error(Nil)
    // skip binary files silently
    Error(e) -> {
      io.println("⚠ Could not read file: " <> real_path)
      io.println("  " <> simplifile.describe_error(e))
      Error(Nil)
    }
  }
}

fn describe_vfs_error(e: vfs.Error) -> String {
  case e {
    vfs.NotFound(p) -> "Not found: " <> p
    vfs.NotEmpty(p) -> "Not empty: " <> p
    vfs.AlreadyExists(p) -> "Already exists: " <> p
    vfs.InvalidPath(p) -> "Invalid path: " <> p
    vfs.SqlError(_) -> "Database error"
  }
}
