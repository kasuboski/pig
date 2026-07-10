import gleam/list
import gleam/string
import gleeunit
import pig/tool
import pig/workspace
import sqlight

pub fn main() {
  gleeunit.main()
}

// Test helper: create a workspace, run a function, then close it
fn with_workspace(f: fn(workspace.Workspace) -> a) -> a {
  let assert Ok(ws) = workspace.open(":memory:")
  let result = f(ws)
  let assert Ok(Nil) = workspace.close(ws)
  result
}

// Test 1: Open memory workspace succeeds and closes cleanly
pub fn open_memory_succeeds_test() {
  let assert Ok(ws) = workspace.open(":memory:")
  let assert Ok(_) = workspace.close(ws)
}

// Test 2: Open returns usable workspace
pub fn open_returns_workspace_test() {
  with_workspace(fn(ws) {
    // If we got here, the workspace is usable
    let conn = workspace.connection(ws)
    // Should be able to execute a simple query
    let assert Ok(_) = sqlight.exec("SELECT 1", on: conn)
    Nil
  })
}

// Test 3: Close succeeds
pub fn close_succeeds_test() {
  let assert Ok(ws) = workspace.open(":memory:")
  let result = workspace.close(ws)
  let assert Ok(_) = result
}

// Test 4: Connection escape hatch works
pub fn connection_escape_hatch_test() {
  with_workspace(fn(ws) {
    let conn = workspace.connection(ws)
    // Should be able to execute a query directly on the connection
    let assert Ok(_) = sqlight.exec("SELECT 1 as value", on: conn)
    Nil
  })
}

// Test 5: Write and read file
pub fn write_and_read_file_test() {
  with_workspace(fn(ws) {
    let path = "/file.txt"
    let content = "Hello, World!"

    let assert Ok(Nil) = workspace.write_file(ws, path, content)
    let assert Ok(read_content) = workspace.read_file(ws, path)

    assert read_content == content
  })
}

// Test 6: Remember and recall
pub fn remember_and_recall_test() {
  with_workspace(fn(ws) {
    let key = "test_key"
    let value = "test_value"

    let assert Ok(Nil) = workspace.remember(ws, key, value)
    let assert Ok(recalled_value) = workspace.recall(ws, key)

    assert recalled_value == value
  })
}

// Test 7: all_tools returns well-formed tools with unique names.
pub fn all_tools_returns_well_formed_tools_test() {
  with_workspace(fn(ws) {
    let tools = workspace.all_tools(ws)
    // Must be non-empty
    assert list.is_empty(tools) == False
    // Every tool must have a non-empty name and description
    let all_valid =
      tools
      |> list.all(fn(t: tool.Tool) {
        string.length(t.definition.name) > 0
        && string.length(t.definition.description) > 0
      })
    assert all_valid == True
    // Names must be unique
    let names =
      tools
      |> list.map(fn(t: tool.Tool) { t.definition.name })
    assert list.length(names) == list.length(list.unique(names))
  })
}
