# pig

A Gleam ecosystem for building, running, and operating AI agents on the BEAM.
`pig` is inspired by the architecture of [pi](https://pi.dev) and uses OTP
processes for isolated, resilient agent execution.

## Packages

| Package | Description | Documentation |
|---|---|---|
| [`pig`](packages/pig) | Agent runtime, tools, skills, hooks, persistence, and observability | [README](packages/pig/README.md) |
| [`pig_protocol`](packages/pig_protocol) | Shared message types and OpenAI-compatible codecs | [README](packages/pig_protocol/README.md) |
| [`pig_transport`](packages/pig_transport) | Cancellable buffered and streaming HTTP transport primitives | [README](packages/pig_transport/README.md) |
| [`pig_proxy`](packages/pig_proxy) | OpenAI-compatible proxy with routing, retries, metrics, and telemetry | [README](packages/pig_proxy/README.md) |
| [`pig_otel`](packages/pig_otel) | Shared tracing semantics and propagation | [README](packages/pig_otel/README.md) |

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

Use `pig.run` for ordinary User prompts or `pig.run_turn` with
`pig/turn.Developer(...)` for application-originated steering/context. The
configured `system_prompt` remains standing guidance, separate from those
conversation turns. Turns are serialized (a concurrent turn returns Busy); use
`run_continue` explicitly to resume committed history after restart. See
[`packages/pig/README.md`](packages/pig/README.md) for durability limits,
provider requirements, tools, timeouts, and development instructions.

## OpenTelemetry

Pig and both proxy inference routes trace runs/inference/tools and HTTP
server/logical/attempt lifetimes, including streaming. Metadata-only is the
default; `pig.with_tracing(config, pig_otel.Disabled)` and
`pig_proxy/config.with_tracing(config, pig_otel.Disabled)` disable Pig spans
while preserving sanitized parent propagation. The host owns SDK/exporter setup
and shutdown; production library dependencies contain only the OTel API.

Direct Pig and proxy tracing share one `pig_otel.Policy`: metadata-only by
default, explicitly bounded `Conversation(options)` capture, or `Disabled`.
Direct Pig projects normalized inference requests/results; the proxy projects
its observed upstream JSON/SSE. They share projection, redaction and limits,
without claiming identical source-byte provenance or provider-wire payloads.
See the [tracing guide](knowledge/OPENTELEMETRY.md),
[capture guide](knowledge/OPENTELEMETRY_CONTENT_CAPTURE.md),
[validation runbook](knowledge/OPENTELEMETRY_VALIDATION.md), and
[local host example](packages/pig_otel/examples/local_validation/README.md).
The [subscription proxy host](packages/pig_proxy/examples/subscriptions/README.md)
shows a self-contained ChatGPT/z.ai operational deployment with opt-in Latitude export.
The local suite needs no model credentials and accepts only the documented
third-party Mist/Gramps deprecations; project warnings remain errors:

```sh
mise run test-integration-otel
```

## Repository structure

```text
packages/
  pig/           Core agent library and examples
  pig_protocol/  Shared protocol types and codecs
  pig_transport/ Cancellable generic HTTP primitives
  pig_proxy/     Standalone proxy service
  pig_otel/      Metadata-only tracing semantics and local host validation
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
atomic cross-package change can build before any package is published. The tracing
integration also consumes a commit-pinned upstream Git binding; the existing Hex
publication wizard does not handle this dependency graph. Publishing `pig_otel`
and making the Git binding available through Hex require a separate release step.
For the existing published package workflow, run the wizard from an up-to-date
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
