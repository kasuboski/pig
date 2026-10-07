# OpenTelemetry

This page documents the maintained tracing contract for Pig. For reproducible
checks, see [OPENTELEMETRY_VALIDATION.md](OPENTELEMETRY_VALIDATION.md).

## Ownership and dependencies

Pig reuses the `otel_gleam` binding; it does not implement an SDK or exporter.
`pig_otel` contains shared semantic mapping, propagation policy and the single
private content decoder/redactor/limits FFI. `pig` owns agent/run/inference/tool
lifetimes; `pig_proxy` owns HTTP ingress, logical inference and physical attempts.
Their separate OTP FFI helpers remain for crash guards, monitors, handoffs and
shutdown ownership, not duplicate OTel API calls. `pig_protocol` and
`pig_transport` remain OTel-independent. The host owns SDK/exporter dependencies,
resource and sampler
configuration, credentials, collector settings, flush and shutdown. Production
Pig packages do not start or configure the global SDK.

## Subscription host OTLP export

The subscriptions example owns SDK/exporter setup and uses standard
`OTEL_EXPORTER_OTLP_*` environment settings. Either
`OTEL_EXPORTER_OTLP_ENDPOINT` (base URL; exporter appends `/v1/traces`) or
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` (complete trace URL, no path appended)
enables export; the trace-specific endpoint wins when both are set. Protocol and
headers are optional. The host accepts only the exact raw protocol spelling
`http/protobuf`; no case or whitespace normalization occurs. It supports exact
raw `OTEL_TRACES_EXPORTER` values `otlp` and `none`; an endpoint enables the SDK
unless `OTEL_SDK_DISABLED=true` or exporter `none` opts out. Standard generic
and trace-specific headers are supported. Pinned exporter gzip support is not
covered by the local receiver. The subscriptions Compose `env_file` forwards these variables from
its private env file.

Latitude uses that same standard exporter path (full trace endpoint and ordinary
OTLP headers), not a vendor-specific mode. An unauthenticated tailnet collector
is safe only when its listener, tailnet ACLs and firewall restrict access to
trusted peers. Never expose an unauthenticated collector publicly; the host does
not detect tailnet trust. The example's parent-based sampler uses 100% root
sampling for accounting while respecting valid parent decisions. Do not impose
this as a forced backend-global sampling policy.

The subscription exporter adapter bounds requests by at most four spans, not a
strict encoded-byte limit; it processes batches sequentially and preserves span
and resource records. The pinned exporter does not support
`OTEL_EXPORTER_OTLP_TIMEOUT` or `OTEL_EXPORTER_OTLP_TRACES_TIMEOUT`; document
only the existing SDK/transport timeout behavior, not a new 30-second cap.
Queue limits, failure delivery behavior and best-effort shutdown details are in the
[subscription deployment guide](../packages/pig_proxy/examples/subscriptions/README.md).

Binding public API and setup: [otel_gleam README](https://github.com/kasuboski/otel_gleam/tree/93b9d101426f7ab8e4ec28136acedf31d3e1e8f4).
The implementation is pinned to that actual upstream Git revision; do not
substitute a local fork or duplicate its FFI. The related [binding contract](https://github.com/kasuboski/otel_gleam/blob/93b9d101426f7ab8e4ec28136acedf31d3e1e8f4/knowledge/OTEL_BINDING_SPEC.md)
describes generic API behavior.

Convention baselines are [GenAI snapshot `8a3767d6c5d09bc0917722720973c0c44182d960`](https://github.com/open-telemetry/semantic-conventions-genai/tree/8a3767d6c5d09bc0917722720973c0c44182d960),
[HTTP v1.44.0](https://github.com/open-telemetry/semantic-conventions/tree/v1.44.0/docs/http),
[OTel API 1.5.0](https://github.com/open-telemetry/opentelemetry-erlang/tree/opentelemetry_api/v1.5.0/apps/opentelemetry_api),
[SDK 1.7.0](https://github.com/open-telemetry/opentelemetry-erlang/tree/opentelemetry/v1.7.0/apps/opentelemetry),
and [exporter 1.10.0](https://github.com/open-telemetry/opentelemetry-erlang/tree/opentelemetry_exporter/v1.10.0/apps/opentelemetry_exporter).
These are integration pins, not claims of latest versions.

## Capture and privacy

`pig_otel.Policy` is shared by direct `pig` and `pig_proxy`: `MetadataOnly`
(default), `Conversation(options.Options)`, or `Disabled`. Capture is explicit,
per consumer config, and never enabled by environment. Direct Pig projects
resolved post-hook/default messages and tool definitions, authored system
instructions and skills, and completed inference output. Its opaque system
prompt state keeps authored guidance separate from the generated tool listing;
capture excludes that generated block and does not represent the entire provider
`InferenceRequest.system_prompt`. The proxy projects observed Chat/Responses
JSON or SSE. Both use the shared `pig_otel/content` implementation, while their
source-byte budgets reflect different input provenance. Provider prompt
bytes/order are unchanged. See the
[capture guide](OPENTELEMETRY_CONTENT_CAPTURE.md) for projection, limits and
privacy boundaries.

Metadata-only adapters accept known safe metadata, not arbitrary data requiring
sanitization. Do not pass content, credentials, raw exception text, arbitrary
baggage, or raw URLs through those adapters. Error categories are bounded and
lossy; omitted provider detail is not reconstructed as a `content_filter`
reason. Failures set Error status without a description or exception event.
Unknown counts/settings remain absent, not invented. Explicit conversation capture uses
a separate shared projection boundary. Rich session/audit events and developer
logs remain separate channels and may have different content characteristics;
metadata-only tracing does not sanitize them.

`Disabled` makes no Pig spans and no tracer lookup, but preserves a supplied
explicit parent. Proxy header scrubbing applies regardless of policy or SDK.
Trace facts must not become unbounded metric labels. `pig_proxy` carries its own
runtime metric emitter; do not use global metric state to route one runtime's
measurements into another.

## Context, scope and lifetime

Tracer marker functions belong to the consuming OTP application: marker module
identity determines the binding's application scope. Resolve a tracer after host
SDK setup, at each accepted operation. Successful lookup without an SDK is a
usable no-op; marker lookup failure disables affected spans and is diagnosed
internally, without substituting a default tracer. A cached no-op tracer remains
no-op. SDK stop/restart is supported only between completed operations; contexts,
spans and tracers are VM-local handles and are not persisted or serialized.

Starting a span does not install its context in another process. Pass explicit
contexts to workers and scope the actual callback with the binding's context API.
See the binding's public API and the [Pig consumer implementation](../packages/pig/src/pig/agent/tracing.gleam)
for verified signatures and process handoffs; do not create spans in a message
dispatcher and assume context propagation.

The runtime arbitrates terminal outcomes and owns cleanup. Atomic span end does
not detect owner death, select between competing terminal results, or guarantee
export. `pig` run spans cover accepted buffered/streaming/continued runs through
durable terminal decisions. Inference spans stay open through terminal handling
or cancellation; tool spans are siblings of inference spans under the run. Caller
context is captured at operation admission. Rejected busy work is not an accepted
run.

The proxy traces both `/v1/chat/completions` and `/v1/responses`, buffered and
streaming: HTTP SERVER ingress, logical GenAI CLIENT operation, and physical
HTTP CLIENT attempts. Retries/fallbacks belong to one logical operation; a skipped
circuit has no physical send. Streaming has three independently owned lifetimes:
server, logical inference and committed physical attempt. Header receipt alone
does not commit a transport response. Acknowledged supervised ownership and
handoffs preserve cleanup across body-read, chunk delivery and downstream
termination. The HTTP server span ends at application completion (buffered
response construction or application terminal chunk callback), not Mist's final
wire write or proof of remote receipt. Runtime `stop` acknowledgement is not
physical connection drain.

## Propagation

Use the safe `otel_gleam_propagator_baggage` alongside Trace Context only in
the subscriptions host; Pig does not parse W3C headers or change propagator
globally. Proxy ingress extracts context and considers only the exact allowlist
`session.id` and `gen_ai.conversation.id`; arbitrary baggage is never copied to
spans. Each supplied, validated identity is explicitly promoted to attributes
on every proxy span in that request, including server, logical inference and
physical attempt spans; baggage itself is not automatically converted to span
attributes. Identity values are preserved exactly, bounded, and rejected rather
than truncated when invalid or oversized. U+FFFD is rejected, including when
emitted by decoding malformed UTF-8. Before outbound injection remove all duplicate,
mixed-case `traceparent`, `tracestate` and `baggage`; inject from the selected
operation/attempt context, then remove baggage again. Preserve unrelated headers.
Built-in providers inject at the `openai.do_stream` request seam for both API
routes. Proxy attempts inject their HTTP child context. Do not install overlapping
HTTP auto-instrumentation for proxy-owned sends unless explicitly coordinated.
Direct custom propagators and throwing custom processors or loaders are not
covered by the supported contract.

## Host shutdown

Stop accepting HTTP work, complete supported terminal cleanup, then call the
managed proxy runtime's explicit `runtime.stop(state)` before flushing/stopping
the host SDK. The host—not Pig—performs SDK/exporter flush and shutdown. A flush
return alone is not delivery proof; a receiver acknowledgement is required when
claiming remote OTLP delivery. Hosts using externally assembled runtime state
without managed supervision own that lifecycle. Process hard kill and VM death
cannot guarantee span completion/export.

## Metrics and logs

`:telemetry`/Prometheus remain the lightweight operational metric channel;
`:logger` is for internal diagnostics not already represented there. Direct OTel
spans own execution timing, parentage and terminal status independently of those
metrics. Do not duplicate telemetry-covered operations in developer logs. Pig
does not provide a metrics/logs SDK or an automatic telemetry-to-span bridge. Host-added auto instrumentation can create
duplicate spans and must be coordinated.

For concrete host and package APIs, see [pig_otel](../packages/pig_otel/README.md),
[pig](../packages/pig/README.md), [pig_proxy](../packages/pig_proxy/README.md),
and the [local validation host](../packages/pig_otel/examples/local_validation/README.md).
