//// Tool wrappers for pig workspace operations.
////
//// This module provides tools that wrap workspace kv and vfs operations
//// as `pig.tool.Tool` values that can be registered with pig agents.
////
//// Each tool closes over a `sqlight.Connection` and provides a handler
//// that parses JSON arguments and calls the appropriate workspace function.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import jscheam/schema
import pig/ai/tool_definition
import pig/tool
import pig/workspace/kv as kv
import pig/workspace/vfs as vfs
import sqlight

// ── Error conversion ────────────────────────────────────────────────

/// Convert VFS errors to ToolError.
fn vfs_error_to_tool_error(err: vfs.Error) -> tool.ToolError {
  case err {
    vfs.NotFound(path) ->
      tool.ToolError(message: "File not found: " <> path)
    vfs.NotEmpty(path) ->
      tool.ToolError(message: "Directory not empty: " <> path)
    vfs.AlreadyExists(path) ->
      tool.ToolError(message: "Already exists: " <> path)
    vfs.InvalidPath(path) ->
      tool.ToolError(message: "Invalid path: " <> path)
    vfs.SqlError(_) -> tool.ToolError(message: "Database error")
  }
}

/// Convert KV errors to ToolError.
fn kv_error_to_tool_error(err: kv.Error) -> tool.ToolError {
  case err {
    kv.NotFound(key) -> tool.ToolError(message: "Key not found: " <> key)
    kv.SqlError(_) -> tool.ToolError(message: "Database error")
  }
}

/// Helper to get optional int field with default value.
fn get_optional_int(args: dynamic.Dynamic, field: String, default: Int) -> Int {
  case decode.run(args, decode.at([field], decode.int)) {
    Ok(val) -> val
    Error(_) -> default
  }
}

// ── Tool constructors ───────────────────────────────────────────────

/// Create a read_file tool.
///
/// Parameters:
/// - path: String (required) - file path
/// - offset: Int (optional) - line number to start from (0-indexed)
/// - limit: Int (optional) - maximum number of lines to read
///
/// Returns file content with line numbers in "N\\tline" format.
pub fn read_file_tool(conn: sqlight.Connection) -> tool.Tool {
  tool.Tool(
    definition:
      tool_definition.ToolDefinition(
        name: "read_file",
        description:
          "Read file contents with line numbers. Use offset and limit to read specific ranges.",
        parameters:
          schema.object([
            schema.prop("path", schema.string()),
            schema.optional(schema.prop("offset", schema.integer())),
            schema.optional(schema.prop("limit", schema.integer())),
          ]),
      ),
    handler: fn(args) {
      case decode.run(args, decode.field("path", decode.string, decode.success)) {
        Ok(path) -> {
          let has_offset = decode.run(args, decode.at(["offset"], decode.int))
            |> result.is_ok
          let has_limit = decode.run(args, decode.at(["limit"], decode.int))
            |> result.is_ok

          case has_offset || has_limit {
            True -> {
              // Explicit offset/limit — use read_file_lines
              let offset = get_optional_int(args, "offset", 0)
              let limit = get_optional_int(args, "limit", 0)
              // limit 0 means "read all from offset"
              let effective_limit = case limit {
                0 -> {
                  // Read full file, count lines from offset onward
                  case vfs.read_file(conn, path) {
                    Ok(content) ->
                      content
                      |> string.split("\n")
                      |> list.drop(offset)
                      |> list.length()
                    Error(_) -> 10_000
                  }
                }
                n -> n
              }
              vfs.read_file_lines(conn, path, offset, effective_limit)
              |> result.map_error(vfs_error_to_tool_error)
              |> result.map(json.string)
            }
            False -> {
              // No offset/limit — read full file with line numbers
              vfs.read_file(conn, path)
              |> result.map_error(vfs_error_to_tool_error)
              |> result.map(format_with_line_numbers)
              |> result.map(json.string)
            }
          }
        }
        Error(_) ->
          Error(tool.ToolError(
            message:
              "Invalid arguments: expected {\"path\": \"<path>\", \"offset\": <int>, \"limit\": <int>}",
          ))
      }
    },
  )
}

/// Format file content with line numbers (0-indexed).
fn format_with_line_numbers(content: String) -> String {
  content
  |> string.split("\n")
  |> list.index_map(fn(line, index) {
    int.to_string(index) <> "\t" <> line
  })
  |> string.join("\n")
}

/// Create a write_file tool.
///
/// Parameters:
/// - path: String (required) - file path
/// - content: String (required) - file content
///
/// Creates or overwrites a file.
pub fn write_file_tool(conn: sqlight.Connection) -> tool.Tool {
  tool.Tool(
    definition:
      tool_definition.ToolDefinition(
        name: "write_file",
        description: "Create or replace a file with the given content.",
        parameters:
          schema.object([
            schema.prop("path", schema.string()),
            schema.prop("content", schema.string()),
          ]),
      ),
    handler: fn(args) {
      case
        decode.run(
          args,
          decode.field(
            "path",
            decode.string,
            fn(path) {
              decode.field("content", decode.string, fn(content) {
                decode.success(#(path, content))
              })
            },
          ),
        )
      {
        Ok(#(path, content)) ->
          vfs.write_file(conn, path, content)
          |> result.map_error(vfs_error_to_tool_error)
          |> result.map(fn(_) { json.object([]) })
        Error(_) ->
          Error(tool.ToolError(
            message: "Invalid arguments: expected {\"path\": \"<path>\", \"content\": \"<content>\"}",
          ))
      }
    },
  )
}

/// Create a list_directory tool.
///
/// Parameters:
/// - path: String (required) - directory path
///
/// Returns a JSON array of entry names.
pub fn list_directory_tool(conn: sqlight.Connection) -> tool.Tool {
  tool.Tool(
    definition:
      tool_definition.ToolDefinition(
        name: "list_directory",
        description: "List all entries in a directory.",
        parameters:
          schema.object([schema.prop("path", schema.string())]),
      ),
    handler: fn(args) {
      case decode.run(args, decode.field("path", decode.string, decode.success)) {
        Ok(path) ->
          vfs.list_directory(conn, path)
          |> result.map_error(vfs_error_to_tool_error)
          |> result.map(fn(entries) {
            json.array(entries, json.string)
          })
        Error(_) ->
          Error(tool.ToolError(
            message: "Invalid arguments: expected {\"path\": \"<path>\"}",
          ))
      }
    },
  )
}

/// Create a delete_file tool.
///
/// Parameters:
/// - path: String (required) - file or empty directory path
///
/// Deletes a file or empty directory.
pub fn delete_file_tool(conn: sqlight.Connection) -> tool.Tool {
  tool.Tool(
    definition:
      tool_definition.ToolDefinition(
        name: "delete_file",
        description: "Delete a file or empty directory.",
        parameters:
          schema.object([schema.prop("path", schema.string())]),
      ),
    handler: fn(args) {
      case decode.run(args, decode.field("path", decode.string, decode.success)) {
        Ok(path) ->
          vfs.delete_file(conn, path)
          |> result.map_error(vfs_error_to_tool_error)
          |> result.map(fn(_) { json.object([]) })
        Error(_) ->
          Error(tool.ToolError(
            message: "Invalid arguments: expected {\"path\": \"<path>\"}",
          ))
      }
    },
  )
}

/// Create a remember tool.
///
/// Parameters:
/// - key: String (required) - key to store
/// - value: String (required) - value to store
///
/// Stores a key-value pair that persists across conversations.
pub fn remember_tool(conn: sqlight.Connection) -> tool.Tool {
  tool.Tool(
    definition:
      tool_definition.ToolDefinition(
        name: "remember",
        description:
          "Store a value that persists across conversations. Updates if key already exists.",
        parameters:
          schema.object([
            schema.prop("key", schema.string()),
            schema.prop("value", schema.string()),
          ]),
      ),
    handler: fn(args) {
      case
        decode.run(
          args,
          decode.field(
            "key",
            decode.string,
            fn(key) {
              decode.field("value", decode.string, fn(value) {
                decode.success(#(key, value))
              })
            },
          ),
        )
      {
        Ok(#(key, value)) ->
          kv.remember(conn, key, value)
          |> result.map_error(kv_error_to_tool_error)
          |> result.map(fn(_) { json.object([]) })
        Error(_) ->
          Error(tool.ToolError(
            message: "Invalid arguments: expected {\"key\": \"<key>\", \"value\": \"<value>\"}",
          ))
      }
    },
  )
}

/// Create a recall tool.
///
/// Parameters:
/// - key: String (required) - key to retrieve
///
/// Returns the stored value as a JSON string.
pub fn recall_tool(conn: sqlight.Connection) -> tool.Tool {
  tool.Tool(
    definition:
      tool_definition.ToolDefinition(
        name: "recall",
        description: "Retrieve a previously stored value by key.",
        parameters:
          schema.object([schema.prop("key", schema.string())]),
      ),
    handler: fn(args) {
      case decode.run(args, decode.field("key", decode.string, decode.success)) {
        Ok(key) ->
          kv.recall(conn, key)
          |> result.map_error(kv_error_to_tool_error)
          |> result.map(json.string)
        Error(_) ->
          Error(tool.ToolError(
            message: "Invalid arguments: expected {\"key\": \"<key>\"}",
          ))
      }
    },
  )
}

/// Create a list_keys tool.
///
/// Parameters:
/// - prefix: String (required) - key prefix to match
///
/// Returns a JSON array of matching keys.
pub fn list_keys_tool(conn: sqlight.Connection) -> tool.Tool {
  tool.Tool(
    definition:
      tool_definition.ToolDefinition(
        name: "list_keys",
        description: "List all stored keys matching a prefix.",
        parameters:
          schema.object([schema.prop("prefix", schema.string())]),
      ),
    handler: fn(args) {
      case
        decode.run(args, decode.field("prefix", decode.string, decode.success))
      {
        Ok(prefix) ->
          kv.list_keys(conn, prefix)
          |> result.map_error(kv_error_to_tool_error)
          |> result.map(fn(keys) {
            json.array(keys, json.string)
          })
        Error(_) ->
          Error(tool.ToolError(
            message: "Invalid arguments: expected {\"prefix\": \"<prefix>\"}",
          ))
      }
    },
  )
}

/// Return all workspace tools in a list.
///
/// The tools are:
/// - read_file: Read file contents with line numbers
/// - write_file: Create or replace a file
/// - list_directory: List entries in a directory
/// - delete_file: Delete a file or empty directory
/// - remember: Store a key-value pair
/// - recall: Retrieve a stored value
/// - list_keys: List keys matching a prefix
pub fn all_tools(conn: sqlight.Connection) -> List(tool.Tool) {
  [
    read_file_tool(conn),
    write_file_tool(conn),
    list_directory_tool(conn),
    delete_file_tool(conn),
    remember_tool(conn),
    recall_tool(conn),
    list_keys_tool(conn),
  ]
}
