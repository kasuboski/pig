import gleeunit
import jscheam/schema
import pig/ai/tool_definition

pub fn main() -> Nil {
  gleeunit.main()
}

// --- Construction Tests ---

pub fn tool_definition_construction_test() {
  let params =
    schema.object([
      schema.prop("city", schema.string())
        |> schema.description("The city to get weather for"),
    ])
  let td =
    tool_definition.ToolDefinition(
      name: "get_weather",
      description: "Get the current weather for a city",
      parameters: params,
    )
  td.name == "get_weather"
    && td.description == "Get the current weather for a city"
}

// --- Equality Tests ---

pub fn tool_definition_equality_test() {
  let params = schema.object([schema.prop("x", schema.string())])
  let td1 =
    tool_definition.ToolDefinition(name: "a", description: "b", parameters: params)
  let td2 =
    tool_definition.ToolDefinition(name: "a", description: "b", parameters: params)
  td1 == td2
}

pub fn tool_definition_inequality_test() {
  let params = schema.object([schema.prop("x", schema.string())])
  let td1 =
    tool_definition.ToolDefinition(name: "a", description: "b", parameters: params)
  let td2 =
    tool_definition.ToolDefinition(name: "x", description: "b", parameters: params)
  td1 != td2
}

// --- Accessor Tests ---

pub fn name_accessor_test() {
  let td =
    tool_definition.ToolDefinition(
      name: "search",
      description: "",
      parameters: schema.object([]),
    )
  td.name == "search"
}

pub fn description_accessor_test() {
  let td =
    tool_definition.ToolDefinition(
      name: "",
      description: "searches things",
      parameters: schema.object([]),
    )
  td.description == "searches things"
}

pub fn parameters_accessor_test() {
  let params = schema.object([schema.prop("q", schema.string())])
  let td =
    tool_definition.ToolDefinition(
      name: "",
      description: "",
      parameters: params,
    )
  td.parameters == params
}
