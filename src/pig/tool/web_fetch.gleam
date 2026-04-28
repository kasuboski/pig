//// Built-in `web_fetch` tool for simple HTTP GET requests.
////
//// Returns the HTTP status and response body as JSON.
//// Intended as a ready-made tool that library users can register
//// with `pig.with_tool(web_fetch.tool())`.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/result
import gleam/string
import jscheam/schema
import logging
import pig/ai/tool_definition
import pig/tool

/// Create a `web_fetch` tool.
///
/// The tool performs a GET request to the given URL and returns:
///
/// ```json
/// {"status": 200, "body": "<response body>"}
/// ```
///
/// Returns a `ToolError` for invalid URLs, network failures, or non-2xx responses.
pub fn tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "web_fetch",
      description:
        "Fetch the contents of a URL via HTTP GET. "
        <> "Returns the response status code and body.",
      parameters: schema.object([schema.prop("url", schema.string())]),
    ),
    handler: handle,
  )
}

/// Handler for the web_fetch tool.
fn handle(args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
  use url <- result.try(
    decode.run(args, decode.field("url", decode.string, decode.success))
    |> result.map_error(fn(_) {
      tool.ToolError(
        message: "Invalid arguments: expected {\"url\": \"<url>\"}",
      )
    }),
  )

  logging.log(logging.Info, "web_fetch: GET " <> url)

  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) {
      tool.ToolError(message: "Invalid URL: " <> url)
    }),
  )

  use resp <- result.try(
    httpc.send(req)
    |> result.map_error(fn(err) {
      tool.ToolError(message: "HTTP request failed: " <> format_error(err))
    }),
  )

  handle_response(resp)
}

/// Convert a successful response to JSON or a ToolError for non-2xx.
fn handle_response(
  resp: Response(String),
) -> Result(json.Json, tool.ToolError) {
  case resp.status {
    s if s >= 200 && s < 300 ->
      Ok(json.object([
        #("status", json.int(resp.status)),
        #("body", json.string(resp.body)),
      ]))
    status ->
      Error(tool.ToolError(
        message:
          "HTTP "
          <> int.to_string(status)
          <> ": "
          <> string_truncate(resp.body, 500),
      ))
  }
}

/// Format an httpc error into a human-readable string.
fn format_error(err: httpc.HttpError) -> String {
  case err {
    httpc.ResponseTimeout -> "request timed out"
    httpc.InvalidUtf8Response -> "response body was not valid UTF-8"
    httpc.FailedToConnect(ip4:, ip6:) ->
      "failed to connect (ipv4: "
      <> format_socket_error(ip4)
      <> ", ipv6: "
      <> format_socket_error(ip6)
      <> ")"
  }
}

fn format_socket_error(err: httpc.ConnectError) -> String {
  case err {
    httpc.Posix(code:) -> code
    httpc.TlsAlert(code:, detail:) -> code <> ": " <> detail
  }
}

/// Truncate a string to at most `max` characters, appending "..." if truncated.
fn string_truncate(s: String, max: Int) -> String {
  case string.length(s) <= max {
    True -> s
    False -> string.slice(s, 0, max) <> "..."
  }
}
