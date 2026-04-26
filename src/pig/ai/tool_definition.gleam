/// A tool definition describing a function the LLM can invoke.
/// `parameters` is a JSON Schema string.
pub type ToolDefinition {
  ToolDefinition(name: String, description: String, parameters: String)
}
