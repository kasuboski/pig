# pig_otel

Shared OpenTelemetry semantics, propagation, and bounded conversation projection
for Pig on the BEAM. `pig` and `pig_proxy` use the same public `Policy` and the
same `pig_otel/content` implementation; consumer-specific lifecycle ownership
remains in each package. The library depends on `otel_gleam` at remote Git revision
`93b9d101426f7ab8e4ec28136acedf31d3e1e8f4` and official API 1.5.0. It does not
start, configure, flush, or depend on the SDK/exporter in production.

## Consumer Contract

Public consumer types/functions are in `src/pig_otel.gleam`. The additional
pure `describe` and `terminal` functions expose mapping facts for acceptance
checks; they perform no IO.

- Define the zero-argument tracer marker **inside the consumer application**.
  Acquire a fresh backend at each accepted operation after application load and
  host SDK setup. Do not retain a pre-SDK backend across intentional restarts.
- Start explicit owned spans. `start` does not install process-current context.
  Hand `context(span)` across each worker boundary and use the binding's
  `context.with_context` in the process executing the actual callback.
- The consumer owns terminal arbitration and eventual cleanup. `finish` sets
  terminal metadata/status before explicit end; repeated calls after end are
  no-ops. The binding's atomic end does not arbitrate concurrent terminal outcomes
  or detect owner death. Hard kill/VM death do not guarantee delivery.
- `Disabled` creates no spans and performs no tracer lookup, but retains and
  propagates the supplied explicit parent. Lookup failure has the same span
  behavior, emits a fixed internal diagnostic, and never uses a default tracer.
- `Policy` has `MetadataOnly` (default), `Conversation(options.Options)`, and
  `Disabled`. Both `pig.with_tracing` and `pig_proxy/config.with_tracing` accept
  this same choice; there is no separate proxy capture builder/type.
- `MetadataOnly` does not honor a global content opt-in. `Conversation` explicitly
  enables bounded structured projection for direct normalized Pig inference and
  eligible proxy JSON/SSE. Attribute adapters still accept **known metadata
  only**; they are not sanitizers for arbitrary attributes. See the
  [maintained capture contract](../../knowledge/OPENTELEMETRY_CONTENT_CAPTURE.md).
- Agent/tool/route/target names are configured identities, not per-request
  content. Request model is the actual known constructor/request model, not agent
  configuration. Unknown provider/model/defaults stay absent. These trace facts
  must not be reused as unbounded metric labels.

## Semantics

Mappings use GenAI snapshot `8a3767d6c5d09bc0917722720973c0c44182d960` and
HTTP v1.44.0. No unreleased schema URL is fabricated.

- Run: `invoke_agent [name]`, INTERNAL, `pig.run.id` uses the existing accepted ID.
- Inference: `chat [model]`, CLIENT. Responses remains conversational `chat`;
  known API flavor is `openai.api.type=responses` or `chat_completions`. This never
  infers `gen_ai.provider.name=openai` from compatible JSON/auth/API flavor.
- Tool: `execute_tool [name]`, INTERNAL, name/call ID only.
- HTTP ingress: `POST [route]`, SERVER; physical attempt: `POST`, CLIENT, with
  `pig.proxy.target.id`. Duration/completion boundaries belong to the consumers.
- Available response ID/model, normalized finish reason array, and usage are
  mapped. Absent counts stay absent; explicit zero stays zero; negative counts
  are omitted. Cached input uses `gen_ai.usage.cache_read.input_tokens` and is
  never added again to input usage. An independently known cached subset does
  not fabricate an aggregate total. Unknown raw stop reasons become `unknown`.
- Success leaves OTel status Unset. Failure and cancellation set Error with no
  description/exception event, and set `pig.outcome`. Unrecognized error strings
  become `_OTHER`; no arbitrary raw string is forwarded as `error.type`.

The finite accepted error categories are:

```text
timeout deadline_exceeded client_disconnected agent_stopped cancelled
rate_limited authentication invalid_request provider_error transport_error
tool_error tool_blocked tool_not_found invalid_arguments persistence_error
callback_error process_exit http_error upstream_error downstream_error
```

## Propagation

The subscriptions host opts in to the safe `otel_gleam_propagator_baggage`
propagator alongside Trace Context; other hosts retain their own propagator
configuration. Pig implements no W3C/baggage parser. Ingress extraction accepts
only the `session.id` and `gen_ai.conversation.id` baggage keys. Identity values
are exact, bounded values: invalid or oversized values are omitted rather than
truncated, and values containing U+FFFD are rejected (including replacement
characters produced while decoding malformed UTF-8). Arbitrary baggage is never
copied to spans. Outbound strips **all** mixed-case `traceparent`, `tracestate`,
and `baggage` duplicates before official explicit-context injection, then removes
baggage recreated by injection. Unrelated headers retain their spelling, values
and relative order. Credential/hop-by-hop protection remains the HTTP caller's
separate responsibility. Direct custom propagators and throwing custom
processors are outside the supported
[implementation contract](../../knowledge/OPENTELEMETRY.md).

## Acceptance

From this package:

```sh
mise exec -- gleam build --warnings-as-errors
mise exec -- gleam check
mise exec -- gleam test
./fixtures/sdk_recording/run.sh
```

Root tests have no SDK/collector dependency or environment gating. Centralized
checks live in `test/support/harness.gleam`. Pure operation/metadata/error matrices
live in `test/support/matrices.gleam`; carrier fixtures are externalized in
`test_data/headers.json`. Disk loading is outside the pure carrier check.
API-only tests prove lookup/no-lookup behavior through synchronous VM call counts,
fixed diagnostic emission, explicit versus ambient propagation, privacy, callback
failure/context restoration, and no-SDK business callbacks.

The separate `fixtures/sdk_recording` host has SDK 1.7.0 as a **dev dependency**.
Its typed snapshot adapter uses a synchronous official simple processor and
`duplicate_bag` recorder to expose parent IDs, attributes, status, scope and
export/end counts without sleeps. `run.sh` configures the SDK before startup;
ordinary `gleam test` there also passes but its auto-started default SDK warns
about the deliberately absent OTLP exporter. No exporter/network/collector is
used or needed. Neither fixture is proof of Pig/proxy lifecycle integration,
consumer scopes, exporter-outage isolation, or OTLP delivery; those are host and
consumer acceptance gates.
