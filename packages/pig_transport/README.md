# pig_transport

Cancellable HTTP transport primitives for the
[`pig`](https://github.com/kasuboski/pig) agent ecosystem.

`pig_transport` provides a small transport boundary shared by `pig` and
`pig_proxy`. It supports buffered requests and incremental response streaming
without tying callers to a provider protocol.

## Installation

Add the package to a Gleam project:

```sh
gleam add pig_transport
```

`pig_transport` targets Erlang and includes a production adapter backed by
[Hackney](https://hex.pm/packages/hackney).

## Buffered requests

```gleam
import pig_transport
import pig_transport/hackney

pub fn fetch() {
  let request =
    pig_transport.Request(
      method: "GET",
      url: "https://example.com",
      headers: [],
      body: "",
      timeout_ms: 30_000,
    )

  pig_transport.sync(hackney.transport(), request)
}
```

A buffered request returns either a complete `Response` or a
`TransportError`.

## Streaming lifecycle

Streaming uses an opaque `StreamHandle` and ordered lifecycle events:

1. `open` returns immediately without performing upstream I/O on the caller.
2. `Committed`, `Rejected`, or `Failed` reports the response-head decision.
3. After `Committed`, call `start` with a sink to receive body chunks.
4. The sink receives ordered `Chunk` events followed by exactly one terminal
   event: `Done`, `StreamError`, or `Cancelled`.

Non-2xx responses are buffered and delivered as `Rejected`, so callers never
observe a partially committed error response.

Call `cancel` at any point to stop upstream work. Cancellation is idempotent,
and the relay monitors its owner and sink so abandoned streams do not leave the
underlying connection running.

## Custom adapters

A transport contains two functions:

```gleam
pub type Transport {
  Transport(
    sync: fn(Request) -> Response,
    stream: fn(Request, process.Subject(SourceEvent)) -> Nil,
  )
}
```

Custom streaming adapters send `SourceHead`, `SourceChunk`, and one source
terminal event to the relay. Adapters that can close their connection cleanly
can first send `SourceReady` with a cancellation subject.

## Development

From this package directory:

```sh
gleam build --warnings-as-errors
gleam test
```

## License

Apache-2.0
