//// Tools module tests for pig workspace.
////
//// Tests that each tool's handler correctly parses arguments and
//// calls the underlying kv/vfs operations.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import pig/tool
import pig/workspace/kv
import pig/workspace/schema
import pig/workspace/tools
import pig/workspace/vfs
import sqlight

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Test helpers ────────────────────────────────────────────────────

/// Helper function to run a test with a fresh in-memory database.
fn with_db(f: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(Nil) = schema.init(conn)
  let result = f(conn)
  let assert Ok(Nil) = sqlight.close(conn)
  result
}

/// Helper to call a tool handler with JSON arguments.
fn call_handler(
  tool: tool.Tool,
  args: List(#(String, json.Json)),
) -> Result(json.Json, tool.ToolError) {
  let args_json = json.object(args)
  let args_string = json.to_string(args_json)
  let assert Ok(dyn) = json.parse(from: args_string, using: decode.dynamic)
  tool.handler(dyn)
}

// ── Tests ────────────────────────────────────────────────────────────

/// all_tools returns a non-empty list of well-formed tools with unique names.
pub fn all_tools_returns_well_formed_tools_test() {
  with_db(fn(conn) {
    let tools = tools.all_tools(conn)
    // Must be non-empty
    tools
    |> list.is_empty()
    |> should.equal(False)
    // Every tool must have a non-empty name and description
    let all_valid =
      tools
      |> list.all(fn(t: tool.Tool) {
        string.length(t.definition.name) > 0
        && string.length(t.definition.description) > 0
      })
    should.equal(all_valid, True)
    // Names must be unique
    let names =
      tools
      |> list.map(fn(t: tool.Tool) { t.definition.name })
    names
    |> list.length()
    |> should.equal(list.length(list.unique(names)))
  })
}

/// write_file tool creates a file.
pub fn write_file_tool_handler_creates_file_test() {
  with_db(fn(conn) {
    let tool = tools.write_file_tool(conn)

    let assert Ok(_) =
      call_handler(tool, [
        #("path", json.string("/test.txt")),
        #("content", json.string("hello")),
      ])

    // Verify by reading back using vfs directly
    let assert Ok(content) = vfs.read_file(conn, "/test.txt")
    content
    |> should.equal("hello")
  })
}

/// read_file tool returns file content with line numbers.
pub fn read_file_tool_returns_content_test() {
  with_db(fn(conn) {
    // Write a file first
    let assert Ok(_) = vfs.write_file(conn, "/test.txt", "hello\nworld")

    let tool = tools.read_file_tool(conn)

    let assert Ok(result_json) =
      call_handler(tool, [#("path", json.string("/test.txt"))])

    let result_string = json.to_string(result_json)
    // Verify line-numbered output: "0\thello\n1\tworld"
    string.contains(result_string, "0")
    |> should.equal(True)
    string.contains(result_string, "hello")
    |> should.equal(True)
    string.contains(result_string, "1")
    |> should.equal(True)
    string.contains(result_string, "world")
    |> should.equal(True)
  })
}

/// read_file tool returns error for nonexistent file.
pub fn read_file_tool_missing_returns_error_test() {
  with_db(fn(conn) {
    let tool = tools.read_file_tool(conn)

    let assert Error(tool.ToolError(message: msg)) =
      call_handler(tool, [#("path", json.string("/nonexistent.txt"))])

    string.contains(msg, "File not found")
    |> should.equal(True)
    string.contains(msg, "/nonexistent.txt")
    |> should.equal(True)
  })
}

/// list_directory tool returns directory entries.
pub fn list_directory_tool_returns_entries_test() {
  with_db(fn(conn) {
    // Create directory and write two files
    let assert Ok(_) = vfs.mkdir(conn, "/dir")
    let assert Ok(_) = vfs.write_file(conn, "/dir/file1.txt", "a")
    let assert Ok(_) = vfs.write_file(conn, "/dir/file2.txt", "b")

    let tool = tools.list_directory_tool(conn)

    let assert Ok(result_json) =
      call_handler(tool, [#("path", json.string("/dir"))])

    let result_string = json.to_string(result_json)
    string.contains(result_string, "file1.txt")
    |> should.equal(True)
    string.contains(result_string, "file2.txt")
    |> should.equal(True)
  })
}

/// delete_file tool removes a file.
pub fn delete_file_tool_removes_file_test() {
  with_db(fn(conn) {
    // Write a file
    let assert Ok(_) = vfs.write_file(conn, "/test.txt", "hello")

    let tool = tools.delete_file_tool(conn)

    // Delete it
    let assert Ok(_) = call_handler(tool, [#("path", json.string("/test.txt"))])

    // Verify it's gone
    let assert Error(_) = vfs.read_file(conn, "/test.txt")
    True
  })
}

/// remember tool stores a value that recall retrieves.
pub fn remember_tool_stores_value_test() {
  with_db(fn(conn) {
    let remember_tool = tools.remember_tool(conn)
    let recall_tool = tools.recall_tool(conn)

    // Store a value
    let assert Ok(_) =
      call_handler(remember_tool, [
        #("key", json.string("test_key")),
        #("value", json.string("test_value")),
      ])

    // Retrieve it
    let assert Ok(result_json) =
      call_handler(recall_tool, [#("key", json.string("test_key"))])

    let result_string = json.to_string(result_json)
    string.contains(result_string, "test_value")
    |> should.equal(True)
  })
}

/// recall tool returns error for nonexistent key.
pub fn recall_tool_missing_returns_error_test() {
  with_db(fn(conn) {
    let tool = tools.recall_tool(conn)

    let assert Error(tool.ToolError(message: msg)) =
      call_handler(tool, [#("key", json.string("nonexistent_key"))])

    string.contains(msg, "Key not found")
    |> should.equal(True)
    string.contains(msg, "nonexistent_key")
    |> should.equal(True)
  })
}

/// grep tool returns matching lines across files.
pub fn grep_tool_returns_matching_lines_test() {
  with_db(fn(conn) {
    // Write multiple files
    let assert Ok(_) =
      vfs.write_file(conn, "/a.txt", "hello world\nfoo bar\nhello again")
    let assert Ok(_) =
      vfs.write_file(conn, "/b.py", "def hello():\n    pass\nhello()")
    let assert Ok(_) = vfs.write_file(conn, "/c.txt", "no match here")

    let tool = tools.grep_tool(conn)

    let assert Ok(result_json) =
      call_handler(tool, [#("pattern", json.string("hello"))])

    let result_string = json.to_string(result_json)
    // Should find matches in a.txt and b.py but not c.txt
    string.contains(result_string, "/a.txt")
    |> should.equal(True)
    string.contains(result_string, "/b.py")
    |> should.equal(True)
    string.contains(result_string, "/c.txt")
    |> should.equal(False)
    string.contains(result_string, "hello world")
    |> should.equal(True)
    string.contains(result_string, "hello again")
    |> should.equal(True)
    string.contains(result_string, "def hello()")
    |> should.equal(True)
  })
}

/// grep tool filters by include glob.
pub fn grep_tool_filters_by_include_test() {
  with_db(fn(conn) {
    let assert Ok(_) = vfs.write_file(conn, "/a.txt", "findme")
    let assert Ok(_) = vfs.write_file(conn, "/b.py", "findme")

    let tool = tools.grep_tool(conn)

    let assert Ok(result_json) =
      call_handler(tool, [
        #("pattern", json.string("findme")),
        #("include", json.string("*.py")),
      ])

    let result_string = json.to_string(result_json)
    string.contains(result_string, "/b.py")
    |> should.equal(True)
    string.contains(result_string, "/a.txt")
    |> should.equal(False)
  })
}

/// grep tool filters by path prefix.
pub fn grep_tool_filters_by_path_test() {
  with_db(fn(conn) {
    let assert Ok(_) = vfs.mkdir(conn, "/src")
    let assert Ok(_) = vfs.write_file(conn, "/src/main.gleam", "findme")
    let assert Ok(_) = vfs.write_file(conn, "/test.gleam", "findme")

    let tool = tools.grep_tool(conn)

    let assert Ok(result_json) =
      call_handler(tool, [
        #("pattern", json.string("findme")),
        #("path", json.string("/src")),
      ])

    let result_string = json.to_string(result_json)
    string.contains(result_string, "/src/main.gleam")
    |> should.equal(True)
    string.contains(result_string, "/test.gleam")
    |> should.equal(False)
  })
}

/// grep tool respects max_results.
pub fn grep_tool_respects_max_results_test() {
  with_db(fn(conn) {
    let assert Ok(_) =
      vfs.write_file(
        conn,
        "/big.txt",
        "line1 match\nline2 match\nline3 match\nline4 match",
      )

    let tool = tools.grep_tool(conn)

    let assert Ok(result_json) =
      call_handler(tool, [
        #("pattern", json.string("match")),
        #("max_results", json.int(2)),
      ])

    let result_string = json.to_string(result_json)
    // Should only have 2 results, not 4
    string.contains(result_string, "line1 match")
    |> should.equal(True)
    string.contains(result_string, "line2 match")
    |> should.equal(True)
    string.contains(result_string, "line4 match")
    |> should.equal(False)
  })
}

/// grep tool returns error without pattern.
pub fn grep_tool_requires_pattern_test() {
  with_db(fn(conn) {
    let tool = tools.grep_tool(conn)

    let assert Error(tool.ToolError(message: msg)) =
      call_handler(tool, [#("path", json.string("/some/path"))])

    string.contains(msg, "Invalid arguments")
    |> should.equal(True)
    string.contains(msg, "pattern")
    |> should.equal(True)
  })
}

/// list_keys tool returns keys matching prefix.
pub fn list_keys_tool_returns_matching_test() {
  with_db(fn(conn) {
    // Store multiple keys
    let assert Ok(_) = kv.remember(conn, "user:name", "Alice")
    let assert Ok(_) = kv.remember(conn, "user:email", "alice@example.com")
    let assert Ok(_) = kv.remember(conn, "config:theme", "dark")

    let tool = tools.list_keys_tool(conn)

    let assert Ok(result_json) =
      call_handler(tool, [#("prefix", json.string("user:"))])

    let result_string = json.to_string(result_json)
    string.contains(result_string, "user:email")
    |> should.equal(True)
    string.contains(result_string, "user:name")
    |> should.equal(True)
    string.contains(result_string, "config:theme")
    |> should.equal(False)
  })
}
