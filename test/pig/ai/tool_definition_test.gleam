import gleeunit
import pig/ai/tool_definition

pub fn main() -> Nil {
  gleeunit.main()
}

// --- Construction Tests ---

pub fn tool_definition_construction_test() {
  let td =
    tool_definition.ToolDefinition(
      name: "get_weather",
      description: "Get the current weather for a city",
      parameters:
        "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}",
    )
  td.name == "get_weather"
    && td.description == "Get the current weather for a city"
    && td.parameters
      == "{\"type\":\"object\",\"properties\":{\"city\":{\"type\":\"string\"}}}"
}

// --- Equality Tests ---

pub fn tool_definition_equality_test() {
  let td1 =
    tool_definition.ToolDefinition(name: "a", description: "b", parameters: "c")
  let td2 =
    tool_definition.ToolDefinition(name: "a", description: "b", parameters: "c")
  td1 == td2
}

pub fn tool_definition_inequality_test() {
  let td1 =
    tool_definition.ToolDefinition(name: "a", description: "b", parameters: "c")
  let td2 =
    tool_definition.ToolDefinition(name: "x", description: "b", parameters: "c")
  td1 != td2
}

// --- Accessor Tests ---

pub fn name_accessor_test() {
  let td =
    tool_definition.ToolDefinition(
      name: "search",
      description: "",
      parameters: "{}",
    )
  td.name == "search"
}

pub fn description_accessor_test() {
  let td =
    tool_definition.ToolDefinition(
      name: "",
      description: "searches things",
      parameters: "{}",
    )
  td.description == "searches things"
}

pub fn parameters_accessor_test() {
  let td =
    tool_definition.ToolDefinition(
      name: "",
      description: "",
      parameters: "{\"type\":\"object\"}",
    )
  td.parameters == "{\"type\":\"object\"}"
}
