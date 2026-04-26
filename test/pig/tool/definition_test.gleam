import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleeunit
import jscheam/schema
import pig/ai/tool_definition
import pig/tool

pub fn main() -> Nil {
  gleeunit.main()
}

// --- Tool Construction Tests ---

pub fn tool_construction_test() {
  let td = make_weather_definition()
  let handler = fn(_args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
    Ok(json.object([#("temp", json.int(72))]))
  }
  let t = tool.Tool(definition: td, handler: handler)
  t.definition == td
}

pub fn tool_handler_callable_test() {
  let td = make_weather_definition()
  let handler = fn(args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
    case decode.run(args, decode.string) {
      Ok(s) -> Ok(json.object([#("echo", json.string(s))]))
      Error(_) -> Error(tool.ToolError(message: "not a string"))
    }
  }
  let t = tool.Tool(definition: td, handler: handler)
  let input = dynamic.string("test")
  let assert Ok(result) = t.handler(input)
  json.to_string(result) == "{\"echo\":\"test\"}"
}

pub fn tool_handler_can_return_error_test() {
  let td = make_weather_definition()
  let handler = fn(_args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
    Error(tool.ToolError(message: "something went wrong"))
  }
  let t = tool.Tool(definition: td, handler: handler)
  let assert Error(err) = t.handler(dynamic.string("anything"))
  err.message == "something went wrong"
}

// --- Registry: Empty ---

pub fn new_registry_is_empty_test() {
  let registry = tool.new_registry()
  tool.list_definitions(registry) == []
}

// --- Registry: Register & Lookup ---

pub fn register_and_lookup_test() {
  let registry =
    tool.new_registry()
    |> tool.register(make_weather_tool())
  let assert Ok(found) = tool.lookup(registry, "get_weather")
  found.definition.name == "get_weather"
}

pub fn register_multiple_tools_test() {
  let registry =
    tool.new_registry()
    |> tool.register(make_weather_tool())
    |> tool.register(make_search_tool())
  let assert Ok(weather) = tool.lookup(registry, "get_weather")
  let assert Ok(search) = tool.lookup(registry, "search")
  weather.definition.name == "get_weather" && search.definition.name == "search"
}

pub fn lookup_nonexistent_returns_error_test() {
  let registry = tool.new_registry()
  tool.lookup(registry, "no_such_tool") == Error(Nil)
}

pub fn register_overwrite_test() {
  let td_v1 =
    tool_definition.ToolDefinition(
      name: "get_weather",
      description: "v1",
      parameters: schema.object([]),
    )
  let td_v2 =
    tool_definition.ToolDefinition(
      name: "get_weather",
      description: "v2",
      parameters: schema.object([]),
    )
  let handler = fn(_args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
    Ok(json.null())
  }
  let registry =
    tool.new_registry()
    |> tool.register(tool.Tool(definition: td_v1, handler: handler))
    |> tool.register(tool.Tool(definition: td_v2, handler: handler))
  let assert Ok(found) = tool.lookup(registry, "get_weather")
  found.definition.description == "v2"
}

// --- Registry: list_definitions ---

pub fn list_definitions_returns_all_test() {
  let registry =
    tool.new_registry()
    |> tool.register(make_weather_tool())
    |> tool.register(make_search_tool())
  let defs = tool.list_definitions(registry)
  list.contains(defs, make_weather_definition())
    && list.contains(defs, make_search_definition())
}

pub fn list_definitions_empty_registry_test() {
  let registry = tool.new_registry()
  tool.list_definitions(registry) == []
}

// --- ToolError Tests ---

pub fn tool_error_construction_test() {
  let err = tool.ToolError(message: "bad args")
  err.message == "bad args"
}

pub fn tool_error_equality_test() {
  let e1 = tool.ToolError(message: "oops")
  let e2 = tool.ToolError(message: "oops")
  e1 == e2
}

// --- Helpers ---

import gleam/dynamic

fn make_weather_definition() -> tool_definition.ToolDefinition {
  tool_definition.ToolDefinition(
    name: "get_weather",
    description: "Get weather for a city",
    parameters:
      schema.object([
        schema.prop("city", schema.string())
          |> schema.description("City name"),
      ]),
  )
}

fn make_search_definition() -> tool_definition.ToolDefinition {
  tool_definition.ToolDefinition(
    name: "search",
    description: "Search the web",
    parameters:
      schema.object([
        schema.prop("query", schema.string())
          |> schema.description("Search query"),
      ]),
  )
}

fn make_weather_tool() -> tool.Tool {
  tool.Tool(
    definition: make_weather_definition(),
    handler: fn(_args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
      Ok(json.object([#("temp", json.int(72))]))
    },
  )
}

fn make_search_tool() -> tool.Tool {
  tool.Tool(
    definition: make_search_definition(),
    handler: fn(_args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
      Ok(json.object([#("results", json.array([], fn(x) { x }))]))
    },
  )
}
