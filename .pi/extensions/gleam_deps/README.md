# Gleam Deps Search

A Pi extension that lets the agent semantically search the source code of Gleam dependency packages — useful for looking up APIs, types, and usage patterns without leaving the conversation.

## What it does

Registers a `search_gleam_deps` tool that the LLM can call to search across all compiled Gleam packages in `build/packages/`. Results include the source file path, package description, and the most relevant code snippet.

## How it works

### Indexing

On session start, the extension:

1. Opens a SQLite-backed store (via `@tobilu/qmd`) at `.pi/extensions/gleam_deps/.gleam-deps-index.sqlite`
2. Scans `build/packages/` for directories containing `src/*.gleam` files
3. Adds any new packages as collections (already-indexed packages are skipped)
4. Reads each package's `gleam.toml` for its description and attaches it as collection context
5. Runs update + embed to build the search index

Indexing is incremental — it only processes packages that haven't been indexed before. The SQLite database persists across sessions.

### Search

When the agent calls `search_gleam_deps`:

- **`query`** (required) — natural language search term (function name, type, concept, etc.)
- **`package`** (optional) — restrict to a specific package (e.g. `gleam_stdlib`)

Each result includes the file path, package description, and the best-matching code chunk.

### Lifecycle

The store is opened once on `session_start` and closed on `session_shutdown` — no per-call open/close overhead.

## Dependencies

- `@tobilu/qmd` — SQLite-backed semantic search store
- `@mariozechner/pi-coding-agent` — Pi extension API (peer dependency)
- `typebox` — schema definitions (peer dependency)
