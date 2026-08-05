# pig

A Gleam library for building and orchestrating AI agents on the BEAM.

`pig` combines a provider-neutral agent loop with OTP isolation, typed tools,
skills, hooks, durable conversation history, and structured telemetry.

## Installation

```sh
gleam add pig
```

## Basic usage

```gleam
import pig
import pig/openai
import pig_protocol/message

pub fn main() {
  let provider = openai.provider("your-api-key", "gpt-4o-mini")
  let config =
    pig.new(provider.call)
    |> pig.with_model("gpt-4o-mini")
    |> pig.with_system_prompt("You are a helpful assistant.")

  let assert Ok(agent) = pig.start(config)
  let assert Ok(message.Assistant(content:, ..)) =
    pig.run(agent, "Explain OTP in one sentence.")

  echo content
  pig.stop(agent)
}
```

`pig/openai` supports OpenAI-compatible endpoints through
`provider_with_base_url`, so the same runtime can be used with compatible local
or hosted providers.

## Thinking levels

### Why this previously appeared supported

Pig already had a `Thinking` field on assistant messages and Responses requests
included `reasoning.encrypted_content`. Both are response/history features:
neither selected how much reasoning the model should perform. There was no
request configuration for `reasoning_effort` or `reasoning.effort`, so users
were correct that thinking levels could not be set.

### Configuration

Inference settings belong to the agent, not to an individual run. Configure
them while building the agent:

```gleam
import pig_protocol/thinking

let provider = openai.provider("your-api-key", "gpt-5")
let config =
  pig.new(provider.call)
  |> pig.with_thinking_level(thinking.Medium)
```

Available levels are `Off`, `Minimal`, `Low`, `Medium`, `High`, `XHigh`, and
`Max`. The setting is included in every inference request. Use
`pig.set_thinking_level(agent, level)` to change it durably mid-session, or
`pig.reset_inference_settings(agent)` to restore provider-default behavior; session
restoration reapplies the saved setting. `Off` is explicit: it asks the
provider not to use reasoning, while the unset/default setting uses the
provider's default. Runtime-only agents update their in-memory settings and
history; configure a `SessionStore` to make setting and conversation changes
durable across restarts.

A provider default is still useful when demonstrating a provider outside an
agent or when an agent has no explicit setting:

```gleam
let provider =
  openai.provider("your-api-key", "gpt-5")
  |> openai.with_default_thinking_level(thinking.Medium)
```

Use `responses_provider` for OpenAI's Responses API. It uses the same
one-argument `Provider(InferenceRequest)` interface. Responses requests send
`reasoning.effort`; enabled levels also request an automatic provider-generated
reasoning summary. System messages are mapped to Responses `instructions`.
Pig does not maintain a model capability catalog, clamp levels, or promise that
a model supports a selected level; unsupported values are reported by the
provider. Setting changes and inference start/stop events are observable through
Pig's normal events and session persistence.

## Tools

A tool combines a JSON Schema definition with a handler. The agent executes tool
calls and feeds their results back to the provider automatically.

```gleam
import gleam/dynamic/decode
import gleam/json
import jscheam/schema
import pig/tool
import pig_protocol/tool_definition

fn add_tool() -> tool.Tool {
  tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "add",
      description: "Add two integers.",
      parameters: schema.object([
        schema.prop("a", schema.integer()),
        schema.prop("b", schema.integer()),
      ]),
    ),
    handler: fn(context, arguments) {
      // Context is library-owned and identifies this invocation.
      let _ = tool.call_id(context)
      let _ = tool.tool_name(context)
      let decoder = {
        use a <- decode.field("a", decode.int)
        use b <- decode.field("b", decode.int)
        decode.success(a + b)
      }
      case decode.run(arguments, decoder) {
        Ok(total) -> Ok(json.int(total))
        Error(_) -> Error(tool.ToolError("Expected integer fields a and b"))
      }
    },
  )
}
```

Register it while building the configuration:

```gleam
let config =
  pig.new(provider.call)
  |> pig.with_tool(add_tool())
```

## Timeouts and continued runs

Fresh runs use a 120-second default timeout. Explicit and non-panicking variants
are available:

```gleam
pig.run_with_timeout(agent, "Hello", 30_000)
pig.try_run_with_timeout(agent, "Hello", 30_000)
pig.try_run_continue_with_timeout(agent, 30_000)
```

The `try_*` functions return an outer `Error(Nil)` when the actor call times out
or crashes, while preserving the provider's inner result. A timeout does not
cancel in-flight provider or tool work.

Continued runs resume from preloaded history without adding another user
message, supporting checkpoint-and-resume workflows.

## Features

- **Provider-neutral runtime** — providers implement one typed function.
- **OTP agent isolation** — each running agent owns its state in an actor.
- **Parallel tool execution** — independent tool calls run concurrently.
- **Skills and hooks** — compose reusable capabilities and lifecycle policy.
- **Durable history with `SessionStore`** — preload and continue checkpointed conversations.
- **Observability** — structured `:telemetry`, terminal output, and JSONL sessions.
- **Workspace tools** — optional SQLite-backed key/value and virtual-file storage.
- **Supervision** — child specifications for OTP supervision trees.

Shared messages, errors, stop reasons, and provider codecs live in
[`pig_protocol`](https://hex.pm/packages/pig_protocol).

## Examples

The [`examples`](examples) directory includes:

- code review agents
- a knowledge notebook
- URL summarization
- scale testing
- a client/server chat application

Each example is a standalone Gleam project.

## Development

From this package directory:

```sh
gleam test
gleam build --warnings-as-errors
```

From the repository root, run all package tests with:

```sh
mise run test
```

Live integration tests are disabled by default and require provider credentials:

```sh
mise run test-integration
```

## License

Apache-2.0
