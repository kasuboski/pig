//// Code Reviewer — a real code reviewer powered by pig agents.
////
//// Takes a path to a git repository as a CLI argument, extracts the diff,
//// generates an AI summary of changes, loads the repo into a VFS workspace,
//// then runs a thorough code review using an AI agent with filesystem tools.
////
//// ## Running
////
//// Set environment variables for your OpenAI-compatible provider:
////
////   export OPENAI_COMPAT_BASE_URL=http://localhost:11434/v1
////   export OPENAI_COMPAT_API_KEY=ollama
////   export OPENAI_COMPAT_MODEL=llama3
////
//// Then:
////
////   cd examples/code_reviewer
////   gleam run -- /path/to/your/repo
////
//// The agent will:
////   1. Extract the git diff (staged + unstaged, or vs main branch)
////   2. Generate a structured summary of the changes
////   3. Load the repo into a virtual filesystem
////   4. Explore the codebase for context
////   5. Produce a thorough code review

import code_reviewer/args
import code_reviewer/fs
import code_reviewer/git
import envoy
import filepath
import gleam/int
import gleam/io
import gleam/result
import gleam/string
import pig
import pig_protocol/error
import pig_protocol/message
import pig/openai
import pig/workspace
import pig/workspace/tools
import simplifile

// ── CLI Args ────────────────────────────────────────────────────────

fn get_repo_path() -> Result(String, String) {
  case args.get_args() {
    [path] -> Ok(path)
    [path, ..] -> Ok(path)
    [] ->
      Error(
        "Usage: gleam run -- /path/to/repo\n"
        <> "Please provide a path to a git repository.",
      )
  }
}

// ── Config ───────────────────────────────────────────────────────────

fn base_url() -> String {
  envoy.get("OPENAI_COMPAT_BASE_URL")
  |> result.unwrap("http://localhost:11434/v1")
}

fn api_key() -> String {
  envoy.get("OPENAI_COMPAT_API_KEY")
  |> result.unwrap("ollama")
}

fn model_name() -> String {
  envoy.get("OPENAI_COMPAT_MODEL")
  |> result.unwrap("llama3")
}

// ── System Prompts ───────────────────────────────────────────────────

const summary_system_prompt = "You are an expert software engineer. You will be given a git diff and a diff stat summary. Produce a clear, structured summary of the changes.\n\nYour summary should cover:\n1. **Files changed** - list each changed file and what changed in it\n2. **Nature of changes** - is this a bug fix, feature, refactor, etc?\n3. **Key modifications** - what are the most important code changes?\n4. **Potential concerns** - anything that stands out as risky or unusual\n\nBe concise but thorough. Use markdown formatting."

const review_system_prompt = "You are a senior code reviewer. You have access to a virtual filesystem containing:\n- /diffs/summary.md - an AI-generated summary of the changes\n- /diffs/full.diff - the raw git diff\n- /diffs/stat.txt - the diff stat (files changed summary)\n- /repo/ - the full repository source code (excluding dependency directories)\n\n## Your Task\n\n1. Start by reading /diffs/summary.md to understand the high-level changes\n2. Read /diffs/full.diff for the detailed diff\n3. Read /diffs/stat.txt for the list of changed files\n4. Use list_directory to explore /repo/ and understand the project structure\n5. Read the changed files and their surrounding context from /repo/\n6. Use grep to find usages of changed functions/types if needed\n\n## Review Format\n\nProduce a thorough code review covering:\n1. **Summary** - brief recap of what these changes do\n2. **Correctness** - does the diff do what it intends? Any logic errors?\n3. **Side effects** - does it break existing callers or interfaces?\n4. **Security** - any injection, auth, data exposure, or input validation risks?\n5. **Performance** - any performance regressions or inefficiencies?\n6. **Style & Clarity** - naming, readability, language idioms\n7. **Action items** - numbered list of specific issues to address, ordered by severity\n\nBe concise. Use bullet points. Flag showstoppers first."

// ── Main ─────────────────────────────────────────────────────────────

/// Entry point for the code reviewer CLI tool.
///
/// Takes a repository path as a CLI argument, extracts the git diff,
/// generates an AI summary, loads the repo into a VFS workspace,
/// and runs a thorough code review using an AI agent.
pub fn main() {
  io.println("=== Pig Code Reviewer ===")
  io.println("")

  // 1. Parse CLI args
  let repo_path = case get_repo_path() {
    Ok(path) -> path
    Error(msg) -> {
      io.println("Warning: " <> msg)
      io.println("")
      io.println("Example: gleam run -- /path/to/your/repo")
      panic as "No repository path provided"
    }
  }

  let model = model_name()
  io.println("Repository: " <> repo_path)
  io.println("Model: " <> model)
  io.println("Provider: " <> base_url())
  io.println("")

  // 2. Validate path is a git repo
  // .git can be a directory (normal repo) or a file (worktree/submodule)
  let git_dir = filepath.join(repo_path, ".git")
  let is_valid_git = case simplifile.is_directory(git_dir) {
    Ok(True) -> True
    _ ->
      case simplifile.is_file(git_dir) {
        Ok(True) -> True
        _ -> False
      }
  }
  case is_valid_git {
    True -> Nil
    False -> {
      io.println("Warning: Not a git repository: " <> repo_path)
      io.println("  (Could not find .git)")
      panic as "Not a git repository"
    }
  }

  // 3. Open workspace (in-memory SQLite with VFS schema initialized)
  let assert Ok(ws) = workspace.open(":memory:")
  let conn = workspace.connection(ws)

  // ── Phase 0: Git Operations ─────────────────────────────────────

  io.println("Phase 0: Extracting git diff...")

  let diff = case git.get_diff(conn, repo_path) {
    Ok(d) -> d
    Error(msg) -> {
      io.println("Warning: " <> msg)
      panic as "Could not get git diff"
    }
  }

  case git.get_diff_stat(conn, repo_path) {
    Ok(_) -> Nil
    Error(msg) -> io.println("   Warning: Could not get diff stat: " <> msg)
  }
  io.println(
    "   Done. Diff extracted ("
    <> int.to_string(string.length(diff))
    <> " chars)",
  )
  io.println("")

  // ── Phase 1: Summarize ──────────────────────────────────────────

  io.println("Phase 1: Generating change summary...")

  let provider = openai.provider_with_base_url(api_key(), model, base_url())

  // Summary agent - no tools, just a simple call
  let summary_cfg =
    pig.new(provider.call)
    |> pig.with_model("code_reviewer_summary")
    |> pig.with_system_prompt(summary_system_prompt)
    |> pig.with_terminal_output()

  let assert Ok(summary_agent) = pig.start(summary_cfg)

  let diff_stat = case workspace.read_file(ws, "/diffs/stat.txt") {
    Ok(s) -> s
    Error(_) -> "(no stat available)"
  }

  let summary_prompt =
    "Summarize the following changes.\n\n"
    <> "## Diff Stat\n\n"
    <> diff_stat
    <> "\n\n## Full Diff\n\n"
    <> diff

  let summary_result =
    pig.run_with_timeout(summary_agent, summary_prompt, 120_000)

  pig.stop(summary_agent)

  let summary = case summary_result {
    Ok(message.Assistant(content:, ..)) -> {
      io.println("   Done. Summary generated.")
      content
    }
    Ok(other) -> {
      io.println("   Warning: Unexpected summary response:")
      io.println(string.inspect(other))
      "(summary generation failed)"
    }
    Error(error.Timeout) -> {
      io.println("   Warning: Summary timed out.")
      "(summary timed out)"
    }
    Error(error.ApiError(msg)) -> {
      io.println("   Warning: API error: " <> msg)
      "(api error)"
    }
    Error(error.RateLimited) -> {
      io.println("   Warning: Rate limited.")
      "(rate limited)"
    }
    Error(error.InvalidResponse(detail)) -> {
      io.println("   Warning: Invalid response: " <> detail)
      "(invalid response)"
    }
  }

  // Write summary to VFS
  let _ = workspace.write_file(ws, "/diffs/summary.md", summary)
  io.println("")

  // ── Phase 2: Load Repo ──────────────────────────────────────────

  io.println("Phase 2: Loading repository into VFS...")
  let file_count = fs.load_repo(conn, repo_path)
  io.println(
    "   Done. Loaded "
    <> int.to_string(file_count)
    <> " files into virtual filesystem.",
  )
  io.println("")

  // ── Phase 3: Review Agent ───────────────────────────────────────

  io.println("Phase 3: Running code review...")
  io.println("   The agent will explore the codebase and produce a review.")
  io.println(
    "   This may take a few minutes depending on the model and repo size.",
  )
  io.println("")

  // Only give the agent read-only VFS tools
  let read_file_t = tools.read_file_tool(conn)
  let list_dir_t = tools.list_directory_tool(conn)
  let grep_t = tools.grep_tool(conn)

  let review_cfg =
    pig.new(provider.call)
    |> pig.with_model("code_reviewer")
    |> pig.with_system_prompt(review_system_prompt)
    |> pig.with_tool(read_file_t)
    |> pig.with_tool(list_dir_t)
    |> pig.with_tool(grep_t)
    |> pig.with_terminal_output()

  let assert Ok(review_agent) = pig.start(review_cfg)

  let review_prompt =
    "Please review the changes in this repository.\n\n"
    <> "Start by reading /diffs/summary.md, then /diffs/full.diff, "
    <> "then explore /repo/ for surrounding context.\n\n"
    <> "Produce a thorough code review."

  let review_result = pig.run_with_timeout(review_agent, review_prompt, 300_000)

  case review_result {
    Ok(message.Assistant(content:, ..)) -> {
      io.println("\n")
      io.println("=== Code Review ===")
      io.println("")
      io.println(content)
    }
    Ok(other) -> {
      io.println("\nWarning: Unexpected response:")
      io.println(string.inspect(other))
    }
    Error(error.Timeout) -> {
      io.println("\nWarning: Review timed out (5 minute limit).")
      io.println("Try a faster model or increase the timeout.")
    }
    Error(error.ApiError(msg)) -> {
      io.println("\nWarning: API error: " <> msg)
    }
    Error(error.RateLimited) -> {
      io.println("\nWarning: Rate limited - wait a moment and try again.")
    }
    Error(error.InvalidResponse(detail)) -> {
      io.println("\nWarning: Invalid response from provider: " <> detail)
    }
  }

  pig.stop(review_agent)

  // Cleanup
  let _ = workspace.close(ws)

  io.println("")
  io.println("Done.")
}
