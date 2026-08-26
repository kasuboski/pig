# pig

A Gleam ecosystem for building, running, and operating AI agents on the BEAM.
`pig` is inspired by the architecture of [pi](https://pi.dev) and uses OTP
processes for isolated, resilient agent execution.

## Packages

| Package | Description | Documentation |
|---|---|---|
| [`pig`](packages/pig) | Agent runtime, tools, skills, hooks, persistence, and observability | [README](packages/pig/README.md) |
| [`pig_protocol`](packages/pig_protocol) | Shared message types and OpenAI-compatible codecs | [README](packages/pig_protocol/README.md) |
| [`pig_proxy`](packages/pig_proxy) | OpenAI-compatible proxy with routing, retries, metrics, and telemetry | [README](packages/pig_proxy/README.md) |

## Quick start

Install the core agent library:

```sh
gleam add pig
```

```gleam
import pig
import pig/openai
import pig_protocol/message
import pig_protocol/thinking

pub fn main() {
  let provider = openai.provider("your-api-key", "gpt-5")
  let config =
    pig.new(provider)
    |> pig.with_system_prompt("You are a helpful assistant.")
    |> pig.with_thinking_level(thinking.Medium)

  let assert Ok(agent) = pig.start(config)
  let assert Ok(message.Assistant(content:, ..)) =
    pig.run(agent, "What is 7 plus 3?")

  echo content
  pig.stop(agent)
}
```

See [`packages/pig/README.md`](packages/pig/README.md) for features, tool usage,
timeouts, and development instructions.

## Repository structure

```text
packages/
  pig/           Core agent library and examples
  pig_protocol/  Shared protocol types and codecs
  pig_proxy/     Standalone proxy service
knowledge/       Architecture notes, specifications, and testing strategy
```

## Development

This repository uses [mise](https://mise.jdx.dev/) to pin Gleam, Erlang, and
Rebar versions.

```sh
mise install
mise run build
mise run test
```

To work on one package:

```sh
cd packages/pig
gleam build --warnings-as-errors
gleam test
```

### Monorepo package dependencies

The source checkout uses local path dependencies between Pig packages so an
atomic cross-package change can build before any package is published. After a
release is merged, run the interactive publication wizard from an up-to-date
`main` branch:

```sh
scripts/publish.sh
```

The wizard validates the release, publishes `pig_protocol` and `pig_transport`
first, and prepares released dependency ranges for `pig` in a temporary Git
worktree. It can optionally publish `pig_proxy`. Gleam authentication and final
publication prompts remain interactive, while the checked-out `main` branch is
left unchanged. A C compiler (`cc`, supplied by GCC or Clang) is required for
Pig's `esqlite` dependency.

Live provider tests are disabled by default. Run them only with the required
provider credentials configured:

```sh
mise run test-integration
mise run test-integration-protocol
```

## License

Apache-2.0
