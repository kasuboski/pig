# pig

A Gleam library for building and orchestrating agents on the BEAM. `pig` is inspired by the architecture of [pi](https://pi.dev).

### Usage

```gleam
import pig
import pig/ai/message
import pig/ai/openai

pub fn main() {
  // Configure an agent with a provider, system prompt, and tools
  let cfg =
    pig.new(openai.provider("your-api-key", "gpt-4o"))
    |> pig.with_system_prompt("You are a helpful assistant.")
    |> pig.with_tool(my_tool)

  // Start the agent, run a prompt, stop the agent
  let assert Ok(agent) = pig.start(cfg)
  let assert Ok(message.Assistant(content:, ..)) =
    pig.run(agent, "What is 7 plus 3?")
  pig.stop(agent)
}
```

The agent loop handles tool calls automatically — define a tool and it will be executed when the model requests it:

```gleam
import gleam/dynamic/decode
import gleam/json
import jscheam/schema
import pig/ai/tool_definition
import pig/tool

let my_tool = tool.Tool(
  definition: tool_definition.ToolDefinition(
    name: "add",
    description: "Add two numbers.",
    parameters: schema.object([
      schema.prop("a", schema.integer()),
      schema.prop("b", schema.integer()),
    ]),
  ),
  handler: fn(args) {
    let assert Ok(a) =
      decode.run(args, decode.field("a", decode.int, decode.success))
    let assert Ok(b) =
      decode.run(args, decode.field("b", decode.int, decode.success))
    Ok(json.int(a + b))
  },
)
```

### Features

*   **Provider Normalization:** Provides a unified interface for interacting with different model APIs, such as Anthropic and OpenAI. It translates messages and tool calls into a consistent format.
*   **Actor-Based Loop:** Uses Gleam actors to manage conversation state, history, and the execution loop. Each agent runs in its own isolated process.
*   **Parallel Tool Execution:** Executes multiple tool calls concurrently using BEAM processes, allowing for faster task completion when multiple resources are needed.
*   **Telemetry:** Emits structured events via the `:telemetry` library. This allows for monitoring inference steps, token usage, and tool performance through standard BEAM observability tools.
*   **Session Persistence:** Supports recording interaction traces to disk as JSONL files, enabling the review of agent activity after a session is complete.
*   **Context Management:** Handles the assembly of system prompts, tool definitions, and message history into a format suitable for various model providers.

### Architecture

`pig` is designed to run within an OTP supervision tree. It separates the model-specific logic from the execution loop, allowing users to swap providers or adjust persistence strategies without changing the core agent definitions. Since the state is immutable, conversation history can be branched or replayed for debugging and testing.

## Repository Structure

This is a monorepo containing multiple packages under `packages/`:

| Package | Description |
|---|---|
| `packages/pig` | The core agent orchestrator library (with `examples/` inside) |
| `packages/pig_protocol` | Shared codecs and message types (planned) |
| `packages/pig_proxy` | Standalone executable proxy server (planned) |

## Development

```sh
mise run build   # Build all packages and self-contained examples
mise run test    # Run unit tests for all packages
```

To work on a single package:

```sh
cd packages/pig
gleam build   # Build the package
gleam test    # Run the tests
```
