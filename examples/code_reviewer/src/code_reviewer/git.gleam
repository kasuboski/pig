//// Git operations for the code reviewer.
//// Runs git commands via the shell and writes results into the pig VFS.

import gleam/string
import code_reviewer/shell
import pig/workspace/vfs
import sqlight

/// Extract the git diff, selecting a single strategy to avoid overlapping hunks.
/// If the repo has a `main` branch, returns only the diff against main.
/// Otherwise falls back to unstaged + staged combined diff.
pub fn get_diff(conn: sqlight.Connection, repo_path: String) -> Result(String, String) {
  // Create /diffs directory
  let _ = vfs.mkdir(conn, "/diffs")

  // Strategy 1: diff against main branch (covers all changes if main exists)
  let vs_main = case shell.run("git diff main 2>/dev/null", repo_path) {
    Ok(output) -> string.trim(output)
    Error(_) -> ""
  }

  let diff = case vs_main {
    "" -> {
      // Strategy 2: no main branch or no changes vs main — use unstaged + staged
      let unstaged = case shell.run("git diff 2>/dev/null", repo_path) {
        Ok(output) -> string.trim(output)
        Error(_) -> ""
      }
      let staged = case shell.run("git diff --cached 2>/dev/null", repo_path) {
        Ok(output) -> string.trim(output)
        Error(_) -> ""
      }
      unstaged <> "\n" <> staged
    }
    d -> d
  }

  let trimmed = string.trim(diff)
  case trimmed {
    "" ->
      Error("No diff found. Make sure you have changes or a main branch.")
    _ -> {
      let _ = vfs.write_file(conn, "/diffs/full.diff", trimmed)
      Ok(trimmed)
    }
  }
}

/// Get a diff stat summary, using the same single-strategy approach.
pub fn get_diff_stat(
  conn: sqlight.Connection,
  repo_path: String,
) -> Result(String, String) {
  // Ensure /diffs directory exists (defensive, in case call order changes)
  let _ = vfs.mkdir(conn, "/diffs")

  let vs_main = case shell.run("git diff --stat main 2>/dev/null", repo_path) {
    Ok(output) -> string.trim(output)
    Error(_) -> ""
  }

  let stat = case vs_main {
    "" -> {
      let unstaged =
        case shell.run("git diff --stat 2>/dev/null", repo_path) {
          Ok(o) -> string.trim(o)
          Error(_) -> ""
        }
      let staged =
        case shell.run("git diff --cached --stat 2>/dev/null", repo_path) {
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
