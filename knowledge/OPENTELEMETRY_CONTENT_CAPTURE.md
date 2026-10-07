# Conversation Capture

This guide documents the shared, explicit structured-content policy used by
`pig` and `pig_proxy`. It is a bounded projection, not raw-body logging or a
replay record. General tracing ownership, context, propagation and host setup
are in [OPENTELEMETRY.md](OPENTELEMETRY.md); local acceptance gates are in
[OPENTELEMETRY_VALIDATION.md](OPENTELEMETRY_VALIDATION.md).

## Enablement

Capture is off by default. `pig.new` and `config.new` select
`pig_otel.MetadataOnly`; there is no environment-variable/global opt-in. Use the
same policy and validated options at either consumer boundary:

```gleam
import pig
import pig_otel
import pig_otel/content/options
import pig_proxy/config

let policy = pig_otel.Conversation(options.defaults())
let agent_config = pig.new(provider) |> pig.with_tracing(policy)
let proxy_config = config.new(targets) |> config.with_tracing(policy)
```

`with_redacted_keys` and `with_redacted_text` return `Result(Options,
OptionsError)`; handle their errors rather than asserting. To add redaction rules:

```gleam
import gleam/result
import pig_otel/content/options

use capture_options <- result.try(options.with_redacted_keys(options.defaults(), ["customer_secret"]))
use capture_options <- result.try(options.with_redacted_text(capture_options, ["literal-private-value"]))
let cfg = config.new(targets)
  |> config.with_tracing(pig_otel.Conversation(capture_options))
```

`options.with_limits(options, source_bytes, content_bytes)` remains the common
builder: it applies one source/content pair to both directions. Values must be
positive; source is capped at 4 MiB and serialized content at 2 MiB. Use
`options.with_direction_limits` with `InputLimits` and `OutputLimits` when the
directions differ. Current defaults are 4 MiB source / 2 MiB serialized content
for input and 4 MiB source / 64 KiB serialized content for output. The
subscriptions host exposes four optional, independently validated environment
overrides: `PIG_PROXY_CAPTURE_INPUT_SOURCE_BYTES`,
`PIG_PROXY_CAPTURE_INPUT_CONTENT_BYTES`,
`PIG_PROXY_CAPTURE_OUTPUT_SOURCE_BYTES`, and
`PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES`. Host values must be positive integers
within the same respective 4 MiB source and 2 MiB serialized-content caps.

Key rules are limited to 32 entries of 128 bytes each and extend
the built-in case-insensitive fragments `secret`, `token`, `password`, `auth`,
`cookie`, `credential`, `api_key`, and `apikey`. Literal rules allow 32 entries,
256 bytes each. Literal matches in identities omit the capture rather than
rewriting identities and breaking tool linkage.

Configuration is the shared `pig_otel.Policy`: `Disabled`, `MetadataOnly`, or
`Conversation(options)`. Both `pig.with_tracing` and
`pig_proxy/config.with_tracing` receive it; the last call replaces the previous
policy. The same validated options and private `pig_otel_content_ffi` decoder,
redactor and limits serve direct and proxy capture. Shared pure tests and 107
fixtures live under `pig_otel`; they were moved, not copied. OTP owners remain
separate because Pig and the proxy own different lifetimes and worker handoffs.

## Capture sources and representation

Direct Pig captures at each inference boundary. It projects resolved
post-hook/default protocol messages and tool definitions, and separately
projects authored system instructions and skills. Pig's opaque `SystemPrompt`
state keeps authored instructions/skills distinct from the generated tool
listing through `pig.build_agent_config` and supervised configuration. The
capture excludes that generated tool-description block; it does not capture the
entire `InferenceRequest.system_prompt` as a single value. This separation does
not change provider prompt bytes or ordering. The request is normalized protocol
input, not necessarily what a custom provider later sends over its wire. On
inference end, Pig attaches saved bounded input and the completed assistant
result. Buffered and streaming calls use that same completed result; Pig does
not add a second SSE accumulator.

The proxy instead projects the observed upstream JSON or SSE request/response
for eligible Chat Completions and Responses routes. Both sources feed the shared
`pig_otel/content` projection/redaction/limits, but source-byte budgets have
different provenance: normalized relevant string bytes for direct Pig versus
proxy JSON/SSE source bytes. Equal default numeric limits do not make those
sources equivalent.

The shared projection writes JSON-string values for `gen_ai.input.messages`,
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

The default directional budgets are 4 MiB of source and 2 MiB final escaped JSON
for input, and 4 MiB of source and 64 KiB final escaped JSON for output. The
proxy source budget counts SSE framing and ignored metadata; direct Pig counts
relevant normalized string bytes. Limits are hard-capped as described above.
Over-limit,
malformed, incomplete, unsupported, or unsafe projections are omitted rather
than emitted as invalid JSON prefixes or raw fallback. The optional private
`pig.content.{input,output}.status` attributes can report captured, filtered, or
omitted outcomes; status is not guaranteed on every request. Eligibility,
backend availability, and attribute budgets can mean there are no content or
status attributes.

## Timing and failure behavior

Direct Pig projects normalized input before provider-worker dispatch and retains
the bounded projection until inference completion. Completed assistant output is
projected at inference end. The two operations are bounded and add synchronous
work at those boundaries. Proxy input is projected once from the effective
request body at the first actual send, including proxy request adjustments such as
the Chat streaming usage rewrite. This is bounded synchronous work before send; a
retry does not create repeated input capture. Proxy output is only taken from the
selected successful response: buffered JSON or a supported SSE response that
completes in order through source EOF. It is attached to the logical span before
that span ends, not
to server, attempt, tool-run, or direct Pig spans. Buffered output projection is
performed synchronously before the buffered response is returned, adding bounded
work to that path. For SSE, chunks are projected incrementally on the stream
observation path; capture does not wait for the entire stream before forwarding
it, but synchronous per-chunk work can add overhead and is not a latency
guarantee. Stream state is bounded; cancellation, overflow, malformed/incomplete
streams, and unfinished tool arguments discard partial output rather than
exporting a partial transcript. Retry bodies and error bodies are not output
content. Capture failure does not change upstream request or response bodies.

The proxy forwards the effective API request payload unchanged; capture is a
separate projection, not a rewrite of upstream or downstream payload. Direct Pig
capture does not inspect raw provider bodies or capture live SSE tokens. Unknown
custom-provider implementations are represented only by normalized protocol
input/output, not an assertion about actual wire content.

Direct capture includes resolved conversation messages and tool rounds with
protocol IDs. `gen_ai.system_instructions` includes authored system instructions
and skills, but excludes Pig's generated tool-description block. Tool definitions
omit descriptions and schemas. Thinking and media are excluded. Run/tool spans
contain no conversation payload. Successful metadata is preserved; a stop-reason
fallback may be used only in captured content, never to rewrite inference
metadata. Missing, unknown or error stop reasons are omitted rather than
invented. Failed or cancelled outputs are incomplete and are not represented as
completed assistant content. Metadata-only behavior remains
the default; existing global environment configuration does not opt in, and the
binding exposes no recording-state query, so bounded projection may run even
without a recording SDK/sampler.

Proxy capture accepts only supported identity-encoded content; do not assume compressed,
binary or arbitrary content types are captured. Capture eligibility depends on
the observed response form and status. In streaming mode, a missing `Content-Type`
allows the bounded, API-specific SSE projector to validate the response. An
explicit unsupported or conflicting type, or non-identity encoding, still
prevents capture. A 2xx SSE response is not complete merely because a finish
marker arrived; ordered terminal/EOF completion is required. A completed Responses
terminal with an empty `output` array preserves previously completed streamed
items; a non-empty final array remains authoritative, and unfinished items are
still omitted. No promise is made about downstream receipt or wire delivery. The metadata SSE
framer accepts an individual event/frame up to 4 MiB, retaining accepted bytes
in bounded 16 KiB binary blocks rather than a per-byte list. An event exceeding
4 MiB is skipped through its delimiter; later events remain eligible for
metadata decoding. This finite cap is not a guarantee that arbitrarily large
provider events will be parsed. The separate cumulative stream source budget for
conversation capture is currently 4 MiB (provisional): a response can therefore
retain usage, response-ID and finish metadata while its conversation projection
is omitted by that budget. The cumulative content budget does not enlarge the
metadata per-event cap or resolve gaps in output-capture eligibility.

## Privacy and deployment

Redaction is performed on the structured projection, including nested tool JSON,
before serialization. Key and literal rules are not a guarantee that arbitrary
prose is secret-free: user text, tool output, names, or other included text may
contain sensitive values not recognized by configured rules. Capture is an
explicit privacy boundary. Obtain appropriate consent and apply access control,
retention and exporter/backend safeguards. Dedicated headers, credentials, raw
URLs and media fields are not copied as conversation attributes, but that does
not sanitize secrets appearing in conversation text. Proxy tracing promotes only
allowlisted `session.id` and `gen_ai.conversation.id` baggage values as exact,
bounded identity attributes on every proxy span for that request, including
server, logical inference and physical attempt spans. It rejects invalid or
oversized values and any value containing U+FFFD. Baggage is not automatically
converted to span attributes, arbitrary baggage is never copied to spans, and
outbound baggage continues to be stripped.

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

The current maintained gates pass; exact commands, fixture scope and counts are
in the [validation runbook](OPENTELEMETRY_VALIDATION.md). Direct SDK/OTLP
acceptance covers built-in OpenAI Chat Completions and Responses through public
buffered and stream-first operations: four runs, each with two inferences and a
tool span, for 16 consumer spans. Exact GenAI content JSON goldens cover both
tool rounds and verify authored system instructions, post-hook private-input
absence, default nested tool-argument/result redaction, and omission of tool
descriptions, schemas and thinking. The complete exported span set is privacy
scanned. The captured system instructions are authored system guidance and
skills, not a claim to capture the entire provider `InferenceRequest`
`system_prompt` or raw provider wire/custom transforms.

The proxy's maintained shared-SDK gate covers 12 content-positive spans, 16
retry spans, six interrupted spans, and the documented malformed, overflow,
shared-policy and race cases. These checks validate only the exercised
projection, SDK recording and receiver-acknowledged OTLP span sets. They cannot
establish how every backend renders or retains attributes, guarantee that an SDK
will not truncate values, or prove physical downstream wire delivery. Capture is
not zero-latency: direct projection occurs at inference boundaries; proxy input
and buffered output projection are synchronous, while proxy SSE projection is
incremental on the observation path. See the [validation runbook](OPENTELEMETRY_VALIDATION.md)
for current gate details and operational limits.

## Primary sources

- [GenAI span guidance and content policy](https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/docs/gen-ai/gen-ai-spans.md)
- [Pinned message schema](https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/model/gen-ai/gen-ai-input-messages.json), [output schema](https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/model/gen-ai/gen-ai-output-messages.json), [system instructions](https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/model/gen-ai/gen-ai-system-instructions.json), and [tool definitions](https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/model/gen-ai/gen-ai-tool-definitions.json)
- [Gleam OTel binding API pin](https://github.com/kasuboski/otel_gleam/tree/93b9d101426f7ab8e4ec28136acedf31d3e1e8f4)
- [Official API attribute storage](https://github.com/open-telemetry/opentelemetry-erlang/blob/opentelemetry_api/v1.5.0/apps/opentelemetry_api/src/otel_attributes.erl) and [SDK configuration](https://github.com/open-telemetry/opentelemetry-erlang/blob/opentelemetry/v1.7.0/apps/opentelemetry/src/otel_configuration.erl)
