import jscheam/schema.{type Type as SchemaType}

/// A tool definition describing a function the LLM can invoke.
/// `parameters` is a typed JSON Schema built with jscheam.
pub type ToolDefinition {
  ToolDefinition(name: String, description: String, parameters: SchemaType)
}
