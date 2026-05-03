//// Git operations for the code reviewer.
//// Runs git commands via the shell and writes results into the pig VFS.

import gleam/string
import code_reviewer/shell
import pig/workspace/vfs
import sqlight

pub fn get_diff(conn: sqlight.Connection, repo_path: String) -> Result(String, String) {
  // Create /diffs directory
  let _ = vfs.mkdir(conn, "/diffs")

  // Get unstaged changes (working tree vs index)
  let unstaged = case shell.run("git diff", repo_path) {
    Ok(output) -> string.trim(output)
    Error(_) -> ""
  }

  // Get staged changes (index vs HEAD)
  let staged = case shell.run("git diff --cached", repo_path) {
    Ok(output) -> string.trim(output)
    Error(_) -> ""
  }

  // Get diff against main branch (if it exists)
  let vs_main = case shell.run("git diff main", repo_path) {
    Ok(output) -> case string.trim(output) {
      "" -> ""
      diff -> diff
    }
    Error(_) -> ""
  }

  // Combine all available diffs: vs_main (if any) plus unstaged and staged
  let parts = []
  let parts = case vs_main {
    "" -> parts
    d -> [d, ..parts]
  }
  let parts = case unstaged {
    "" -> parts
    d -> [d, ..parts]
  }
  let parts = case staged {
    "" -> parts
    d -> [d, ..parts]
  }
  let diff = string.join(parts, "\n\n")

  let trimmed = string.trim(diff)
  case trimmed {
    "" -> Error("No diff found. Make sure you have changes or a main branch.")
    _ -> {
      let _ = vfs.write_file(conn, "/diffs/full.diff", trimmed)
      Ok(trimmed)
    }
  }
}

pub fn get_diff_stat(conn: sqlight.Connection, repo_path: String) -> Result(String, String) {
  let vs_main = case shell.run("git diff --stat main", repo_path) {
    Ok(output) -> string.trim(output)
    Error(_) -> ""
  }

  let stat = case vs_main {
    "" -> {
      let unstaged = case shell.run("git diff --stat", repo_path) {
        Ok(o) -> string.trim(o)
        Error(_) -> ""
      }
      let staged = case shell.run("git diff --cached --stat", repo_path) {
        Ok(o) -> string.trim(o)
        Error(_) -> ""
      }
      unstaged <> "\n" <> staged
    }
    s -> s
  }

  let trimmed = string.trim(stat)
  case trimmed {
    "" -> Ok("(no stat available)")
    _ -> {
      let _ = vfs.write_file(conn, "/diffs/stat.txt", trimmed)
      Ok(trimmed)
    }
  }
}
