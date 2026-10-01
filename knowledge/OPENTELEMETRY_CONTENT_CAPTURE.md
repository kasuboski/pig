# Proxy Conversation Capture

This guide documents the explicit structured-content option in `pig_proxy`. It
is a bounded projection for the two OpenAI-compatible proxy APIs, not raw-body
logging or a general Pig conversation recorder. General tracing ownership,
context, propagation and host setup are in [OPENTELEMETRY.md](OPENTELEMETRY.md);
local acceptance gates are in [OPENTELEMETRY_VALIDATION.md](OPENTELEMETRY_VALIDATION.md).

## Enablement

Capture is off by default. `config.from_env` selects metadata-only tracing; there
is no environment-variable/global opt-in. Select it on a specific proxy config:

```gleam
import pig_proxy/config
import pig_proxy/content

let cfg = config.new(targets)
  |> config.with_conversation_capture(content.defaults())
```

`with_redacted_keys` and `with_redacted_text` return `Result(Options,
OptionsError)`; handle their errors rather than asserting. To add redaction rules:

```gleam
import gleam/result

use options <- result.try(content.with_redacted_keys(content.defaults(), ["customer_secret"]))
use options <- result.try(content.with_redacted_text(options, ["literal-private-value"]))
let cfg = config.new(targets) |> config.with_conversation_capture(options)
```

`content.with_limits(options, source_bytes, content_bytes)` also returns a
`Result`. Both values must be positive; source is capped at 1 MiB and serialized
content at 256 KiB per direction. Defaults are 64 KiB source and 16 KiB content
per direction. For example, handle validation the same way:

```gleam
use options <- result.try(content.with_limits(options, 32_768, 8_192))
```

Key rules are limited to 32 entries of 128 bytes each and extend
the built-in case-insensitive fragments `secret`, `token`, `password`, `auth`,
`cookie`, `credential`, `api_key`, and `apikey`. Literal rules allow 32 entries,
256 bytes each. Literal matches in identities omit the capture rather than
rewriting identities and breaking tool linkage.

Configuration is a single proxy tracing choice: `Disabled`, `MetadataOnly`, or
`Conversation(options)`. `config.with_tracing(cfg, pig_otel.Disabled | MetadataOnly)`
clears capture; `config.with_conversation_capture` opts in. The last builder wins.
This setting affects only proxy spans; `pig` direct inference and
`pig_otel.Policy` remain metadata-only/disabled and have no direct capture mode.

## Captured representation

For eligible Chat Completions and Responses requests, Pig projects structured
content from request and selected response bodies onto the logical GenAI span
using JSON-string values for `gen_ai.input.messages`,
`gen_ai.output.messages`, `gen_ai.system_instructions`,
and `gen_ai.tool.definitions`. These follow the pinned GenAI schemas at
[revision 8a3767d](https://github.com/open-telemetry/semantic-conventions-genai/tree/8a3767d6c5d09bc0917722720973c0c44182d960): messages are arrays of
role/parts,
output includes the pinned required `finish_reason`, and tool definitions are
represented without descriptions or parameter schemas. Chat choices are
independent outputs. Responses input/output items preserve available
`call_id` linkage; final items can replace earlier streamed representations.

Projection includes text messages, separate Responses instructions, tool calls
and results, and tool names/types. It excludes reasoning (including encrypted
reasoning), media and media URLs, unknown parts, tool descriptions and schema
definitions. Unsupported parts can be filtered, and a capture may omit a whole
attribute when the bounded projection cannot truthfully represent it. This is
not full provider JSON, wire bytes, a replay record, or proof that every item was
observed.

The default bounds reject source beyond 64 KiB cumulatively per direction (SSE
framing and ignored metadata count toward source) and limit final escaped JSON to
16 KiB per direction. Limits are hard-capped as described above. Over-limit,
malformed, incomplete, unsupported, or unsafe projections are omitted rather
than emitted as invalid JSON prefixes or raw fallback. The optional private
`pig.content.{input,output}.status` attributes can report captured, filtered, or
omitted outcomes; status is not guaranteed on every request. Eligibility,
backend availability, and attribute budgets can mean there are no content or
status attributes.

## Timing and failure behavior

Input is projected once from the effective request body at the first actual send,
including proxy request adjustments such as the Chat streaming usage rewrite. This
is a bounded synchronous projection before that send, so it adds work to the
request path; it is not a zero-delay or zero-latency guarantee. A retry does not
create repeated input capture. Output is only taken from the selected successful
response: buffered JSON or a supported SSE response that completes in order
through source EOF. It is attached to the logical span before that span ends, not
to server, attempt, tool-run, or direct Pig spans. Buffered output projection is
performed synchronously before the buffered response is returned, adding bounded
work to that path. For SSE, chunks are projected incrementally on the stream
observation path; capture does not wait for the entire stream before forwarding
it, but synchronous per-chunk work can add overhead and is not a latency
guarantee. Stream state is bounded; cancellation, overflow, malformed/incomplete
streams, and unfinished tool arguments discard partial output rather than
exporting a partial transcript. Retry bodies and error bodies are not output
content. Capture failure does not change upstream request or response bodies.

The proxy forwards the effective API request payload unchanged; verified
forwarding does not apply production normalization. Capture is a separate projection,
not a rewrite of upstream or downstream payload. Direct Pig provider bodies,
direct Pig SSE, and partial/live-token capture are out of scope.

Only supported identity-encoded content is eligible; do not assume compressed,
binary or arbitrary content types are captured. Capture eligibility depends on
the observed response form and status. A 2xx SSE response is not complete merely
because a finish marker arrived; ordered terminal/EOF completion is required.
No promise is made about downstream receipt or wire delivery.

## Privacy and deployment

Redaction is performed on the structured projection, including nested tool JSON,
before serialization. Key and literal rules are not a guarantee that arbitrary
prose is secret-free: user text, tool output, names, or other included text may
contain sensitive values not recognized by configured rules. Capture is an
explicit privacy boundary. Obtain appropriate consent and apply access control,
retention and exporter/backend safeguards. Dedicated headers, credentials, raw
URLs and media fields are not copied as conversation attributes, but that does
not sanitize secrets appearing in conversation text.

Pig uses the existing API-only binding and does not configure the host SDK,
sampler, exporter, attribute limits, or collector. Host SDK string truncation can
make otherwise valid JSON invalid; insufficient attribute slots can drop values.
The local validation gate demonstrates the string-truncation case and rejects
it as a successful capture. Export is best-effort, not a persistence or delivery
guarantee. Ensure SDK, collector and backend limits can accommodate the emitted
values and inspect the receiver when validating actual delivery. The binding does
not expose recording state, so Pig makes no `is_recording` promise or
recording-state check; explicit capture can incur bounded projection work even
with no SDK or an always-off sampler. Disabled/metadata-only modes skip content
capture.

## Validation scope

The maintained clean SDK/OTLP gate passed with 19 enabled integration checks
and 4 ungated verifier checks (23 passed with integration enabled); a separate
invocation verifies the ungated suite. The same 19 integration entrypoints are
reported as no-ops when the integration flag is off, so that invocation's 23
passes are not 23 true unit tests. The shared SDK suite passed 5 tests. Positive
buffered and streaming cases observed 12 actual consumer spans across Chat and
Responses routes through official SDK recording and OTLP receiver
acknowledgement. Additional integration cases cover
malformed streamed JSON, source overflow, a retry whose first attempt failed
with 503, configured capture with no SDK or sampling off, and `Disabled`
precedence. Three fresh-VM interrupted-run repeats each recorded six spans across
both routes, reporting output omitted/incomplete alongside failed or cancelled
outcomes. A full-span privacy sentinel scan and pure regression checks passed.
A deterministic graceful owners-supervisor teardown barrier prevents the
interrupted-fixture snapshot race.

These checks validate only the exercised projection, SDK recording, and
receiver-acknowledged OTLP span sets. They do not establish how every backend
renders or retains attributes, guarantee that an SDK will not truncate values,
or prove physical downstream wire delivery. They also do not make capture
zero-latency: input projection and buffered output projection are synchronous,
while SSE projection is incremental on the observation path. See the
[validation runbook](OPENTELEMETRY_VALIDATION.md) for gate details and operational
limits.

## Primary sources

- [GenAI span guidance and content policy](https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/docs/gen-ai/gen-ai-spans.md)
- [Pinned message schema](https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/model/gen-ai/gen-ai-input-messages.json), [output schema](https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/model/gen-ai/gen-ai-output-messages.json), [system instructions](https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/model/gen-ai/gen-ai-system-instructions.json), and [tool definitions](https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/model/gen-ai/gen-ai-tool-definitions.json)
- [Gleam OTel binding API pin](https://github.com/kasuboski/otel_gleam/tree/0ad06026ba0cdbdd3adfc9dd6ec882cfb8a1c2a5)
- [Official API attribute storage](https://github.com/open-telemetry/opentelemetry-erlang/blob/opentelemetry_api/v1.5.0/apps/opentelemetry_api/src/otel_attributes.erl) and [SDK configuration](https://github.com/open-telemetry/opentelemetry-erlang/blob/opentelemetry/v1.7.0/apps/opentelemetry/src/otel_configuration.erl)
