import gleeunit
import jscheam/schema
import pig
import pig/ai/tool_definition
import pig/tool

pub fn main() {
  gleeunit.main()
}

fn dummy_tool(name: String) -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: name,
      description: "test",
      parameters: schema.object([]),
    ),
    handler: fn(_) { Error(tool.ToolError(message: "test")) },
  )
}

// Test 1: with_tools registers multiple tools
pub fn with_tools_registers_multiple_tools_test() {
  let config = pig.test_harness()
  let tool1 = dummy_tool("tool1")
  let tool2 = dummy_tool("tool2")
  let tool3 = dummy_tool("tool3")

  let updated_config = pig.with_tools(config, [tool1, tool2, tool3])

  let agent_cfg = pig.agent_config(updated_config)

  // All three tools should be registered
  let assert Ok(_) = tool.lookup(agent_cfg.tools, "tool1")
  let assert Ok(_) = tool.lookup(agent_cfg.tools, "tool2")
  let assert Ok(_) = tool.lookup(agent_cfg.tools, "tool3")
}

// Test 2: with_tools with empty list returns same config
pub fn with_tools_empty_list_returns_same_config_test() {
  let config = pig.test_harness()

  let updated_config = pig.with_tools(config, [])

  // Config should be unchanged
  let original_agent_cfg = pig.agent_config(config)
  let updated_agent_cfg = pig.agent_config(updated_config)

  // Both should have empty tool registries
  let assert Error(_) = tool.lookup(original_agent_cfg.tools, "anything")
  let assert Error(_) = tool.lookup(updated_agent_cfg.tools, "anything")
}

// Test 3: with_tools equivalent to individual with_tool calls
pub fn with_tools_equivalent_to_individual_with_tool_test() {
  let config = pig.test_harness()
  let tool_a = dummy_tool("tool_a")
  let tool_b = dummy_tool("tool_b")

  // Using with_tools
  let config_with_tools = pig.with_tools(config, [tool_a, tool_b])

  // Using individual with_tool calls
  let config_individual =
    config
    |> pig.with_tool(tool_a)
    |> pig.with_tool(tool_b)

  // Both should have the same tools registered
  let agent_cfg_with_tools = pig.agent_config(config_with_tools)
  let agent_cfg_individual = pig.agent_config(config_individual)

  let assert Ok(_) = tool.lookup(agent_cfg_with_tools.tools, "tool_a")
  let assert Ok(_) = tool.lookup(agent_cfg_with_tools.tools, "tool_b")
  let assert Ok(_) = tool.lookup(agent_cfg_individual.tools, "tool_a")
  let assert Ok(_) = tool.lookup(agent_cfg_individual.tools, "tool_b")
}
