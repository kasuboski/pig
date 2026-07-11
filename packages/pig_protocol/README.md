# pig_protocol

Shared, provider-neutral message types and OpenAI-compatible codecs for the
[`pig`](https://github.com/kasuboski/pig) agent ecosystem.

`pig_protocol` provides the protocol boundary used by `pig` and `pig_proxy`:

- normalized messages, tool calls, inference metadata, stop reasons, and errors
- request builders and response parsers for Chat Completions and Responses APIs
- authentication helpers for standard API keys and Codex OAuth tokens
- incremental Server-Sent Events parsing
- transport types for integrating custom HTTP clients

Most codecs and parsers are pure. Network access is isolated behind transport
functions, with a `gleam_httpc` implementation available when needed.

## Installation

Add the package to a Gleam project:

```sh
gleam add pig_protocol
```

## Usage

Build a Chat Completions request and parse its response:

```gleam
import pig_protocol/codec/chat
import pig_protocol/message

pub fn request_body() -> String {
  chat.build_request_body(
    messages: [
      message.System("You are a helpful assistant."),
      message.User("What is 7 plus 3?"),
    ],
    tools: [],
    model: "gpt-4o-mini",
  )
}

pub fn parse_response(body: String) {
  chat.parse_response(body)
}
```

The Responses API has the same pure request/response shape through
`pig_protocol/codec/responses`.

For direct HTTP calls, construct a `pig_protocol/transport.HttpRequest` and use
`pig_protocol/transport/httpc.transport`, or provide your own function matching
`pig_protocol/transport.Transport`.

## Modules

| Module | Purpose |
|---|---|
| `pig_protocol/message` | Unified conversation messages and tool calls |
| `pig_protocol/inference` | Provider response values and metadata |
| `pig_protocol/error` | Normalized provider errors |
| `pig_protocol/stop_reason` | Provider-neutral completion reasons |
| `pig_protocol/tool_definition` | JSON Schema-backed tool definitions |
| `pig_protocol/codec/chat` | Chat Completions request and response codecs |
| `pig_protocol/codec/responses` | Responses API and Codex codecs |
| `pig_protocol/sse` | Incremental SSE frame and event parsing |
| `pig_protocol/auth` | Standard API and Codex OAuth endpoint helpers |
| `pig_protocol/transport` | HTTP transport interfaces |
| `pig_protocol/transport/httpc` | `gleam_httpc` transport implementation |

## Development

From the repository root:

```sh
cd packages/pig_protocol
gleam test
gleam build --warnings-as-errors
```

Live integration tests are disabled by default. Run them through the repository's
integration task with the required provider credentials configured:

```sh
mise run test-integration-protocol
```

## License

Apache-2.0
