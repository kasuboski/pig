# Subscription proxy host

A self-contained BEAM host for exact ChatGPT subscription Responses and z.ai
Coding Plan ChatCompletions routes. The host owns the official OpenTelemetry SDK
and OTLP exporter graph; these dependencies do not enter the `pig_proxy`
library graph.

## Configure and run

Log in with Pig's Codex OAuth device flow, which persists credentials at
`~/.pig/codex_auth.json` by default (override with `PIG_CODEX_AUTH_PATH`). At
runtime, a readable, parseable credentials file takes precedence; the optional
`OPENAI_COMPAT_CODEX_TOKEN` is only a fallback seed without token refresh. The
host loads the configured file to check that its credential fields are nonblank,
or checks the seed when the file cannot be loaded. It never displays credentials.
This checks local availability, not subscription entitlement or upstream acceptance.

```sh
mise run codex-login
export PIG_CHATGPT_MODELS="YOUR_CHATGPT_MODEL_ID" # exact upstream IDs, comma-separated
export PIG_ZAI_MODELS="YOUR_ZAI_MODEL_ID"
export ZAI_API_KEY="..."
mise run run-subscriptions
```

Required variables are `PIG_CHATGPT_MODELS`, `PIG_ZAI_MODELS`, and
`ZAI_API_KEY`. Model lists are trimmed, non-empty, exact names; duplicate names
are rejected. ChatGPT routes use provider `openai`, API `Responses`, target
`chatgpt`, and default base URL
`https://chatgpt.com/backend-api/codex`. z.ai routes use provider `zai`, API
`ChatCompletions`, target `zai`, and default base URL
`https://api.z.ai/api/coding/paas/v4`. Optional `PIG_CHATGPT_BASE_URL` and
`PIG_ZAI_BASE_URL` overrides support loopback acceptance tests. `PIG_PROXY_MODELS_DEV_URL` can also
point the pricing catalog at a loopback fixture. At host startup, the subscription
host waits up to five seconds for the first successful catalog fetch before opening
HTTP ingress. If no catalog is published by then, it logs a warning and starts
normally; requests admitted before the next successful refresh have no span-level
price estimate. Later catalog refreshes price later inferences and `/metrics`, but
do not retroactively reprice already-admitted spans. This wait is host-only and
does not block library users or reject inference traffic. URLs must use HTTPS, or
HTTP to loopback, with no embedded credentials, query, or fragment. No model aliases
or request rewriting are performed. The host defaults to `127.0.0.1` (port
8080, optionally `PIG_PROXY_PORT`). Set `PIG_PROXY_BIND=0.0.0.0` only when an
external boundary such as Docker's loopback-only port publishing restricts access.
There is no inbound authentication, so do not expose it to an untrusted network.

## Docker Compose

From the repository root:

```sh
cd packages/pig_proxy/examples/subscriptions
cp .env.example .env
chmod 600 .env
# Edit .env with exact model IDs, ZAI_API_KEY, and optional Latitude settings.
docker compose build
# Preferred: follow the device-login URL/code; credentials stay in a named volume.
docker compose run --rm subscriptions login
docker compose up -d --wait
curl http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/v1/models
```

Compose reads configuration and secrets from the example's `.env`, never from
build arguments. `.env` is git-ignored; the Dockerfile-specific build-context
allowlist excludes environment files, credentials, local build artifacts, tests
and unrelated project files. Use single quotes around values containing `$` to
prevent Compose interpolation. Avoid `docker compose config` without `--quiet`
when real secrets are loaded: rendered configuration includes environment values.

The device flow saves refreshable credentials to `codex_auth`, mounted at
`/home/pig/.pig` for the non-root service user. No host credential file is mounted
or read automatically. Alternatively, set `OPENAI_COMPAT_CODEX_TOKEN` in `.env`
and skip login; that seed cannot refresh, and persisted credentials take precedence.
Leave optional variables unset instead of blank, especially the seed token and URL
overrides. After changing `.env`, run `docker compose up -d` to recreate the service.

The service listens on `0.0.0.0:8080` **inside** the container; Compose pins the bind,
container port and credential path, and publishes only on host `127.0.0.1`.
`PIG_PROXY_HOST_PORT` in `.env` changes the published port without changing the
container port. If the native proxy is already using 8080, choose a different host
port, for example 8081. Containers sharing the Compose network can also reach the
service, so do not attach untrusted containers. OTLP settings in `.env` are
forwarded by the existing `env_file`; no separate Compose mapping is needed.
Export remains disabled when both endpoint variables are unset.

```sh
docker compose logs -f subscriptions
docker compose down
```

Compose forwards SIGTERM and allows 35 seconds for the host's 30-second shutdown
watchdog. The image uses a production Erlang shipment plus the separate official
SDK/exporter graph, not `gleam run`; no build tool or source checkout is needed at
runtime. The container runs as UID/GID 10001 with a read-only root filesystem,
a temporary `/tmp`, dropped capabilities and a writable credential volume.
`docker compose down` preserves credentials; `down -v` deletes them and requires
another login. Do not run login concurrently with the host refreshing the same
credentials: stop the service before replacing an existing login.

To build without Compose, use the **repository root** as context:

```sh
docker build -f packages/pig_proxy/examples/subscriptions/Dockerfile \
  -t pig-subscriptions:local .
```

Compose V2 is required. For an alternate env file, set `PIG_SUBSCRIPTIONS_ENV_FILE`
and pass the same file to Compose, for example
`PIG_SUBSCRIPTIONS_ENV_FILE=/path/to/config.env docker compose --env-file /path/to/config.env up -d`.

## OTLP export and conversation capture

The subscriptions host exports traces through standard OpenTelemetry OTLP
exporter environment variables. There is no Latitude-specific mode or enable
flag: setting either endpoint enables export; with neither endpoint set, traces
are not exported. The official exporter is pinned to 1.10.0. The host accepts only the exact raw protocol spelling `http/protobuf`; it does
not trim whitespace or normalize case. Other values are rejected. The exporter
itself supports gzip compression, but the local receiver checks do not cover
gzip. The host supports `OTEL_TRACES_EXPORTER` values `otlp` and `none` only;
they are matched exactly, without case or whitespace normalization. An endpoint
enables the SDK unless `OTEL_SDK_DISABLED=true` or
`OTEL_TRACES_EXPORTER=none` opts out.

```dotenv
# Base URL; exporter appends /v1/traces.
OTEL_EXPORTER_OTLP_ENDPOINT=http://collector.tailnet.example:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf

# Or specify the complete trace URL (takes precedence over the base URL).
# OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://collector.tailnet.example:4318/v1/traces
# Optional headers; trace-specific values override generic values.
# OTEL_EXPORTER_OTLP_TRACES_HEADERS=Authorization=Bearer TOKEN
```

`OTEL_EXPORTER_OTLP_ENDPOINT` is a base URL; the exporter appends `/v1/traces`.
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` is the complete trace URL, used as supplied,
and takes precedence if both are configured. Endpoint alone enables export;
protocol and headers are optional. The trace-specific protocol
`OTEL_EXPORTER_OTLP_TRACES_PROTOCOL`, when set, overrides
`OTEL_EXPORTER_OTLP_PROTOCOL`. Generic and trace-only headers are supported
through `OTEL_EXPORTER_OTLP_HEADERS` and
`OTEL_EXPORTER_OTLP_TRACES_HEADERS`; trace-specific headers replace generic
headers rather than merging.
In pinned exporter 1.10.0, header strings are comma-separated `key=value` pairs:
comma separates entries, the first `=` separates key and value, whitespace is
trimmed, and one pair of surrounding double quotes is stripped from a value.
The parser does not percent-decode. Avoid commas in values; percent-escaping
cannot be used to pass a comma through this implementation. Keep header values
secret and `.env` private.

A tailnet collector example assumes the container can resolve and reach the
collector hostname. This example uses no collector authentication. Restrict its
listener to the tailnet interface and use tailnet ACLs and host/network firewall
rules to allow only trusted senders. Never expose an unauthenticated collector
on a public interface. The host does not detect tailnet connectivity or infer
that an unauthenticated endpoint is safe.

Latitude uses the same standard settings, without a vendor mode or special
flag. Direct ingestion can be configured as:

```dotenv
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://ingest.latitude.so/v1/traces
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_EXPORTER_OTLP_TRACES_HEADERS=Authorization=Bearer YOUR_API_KEY,X-Latitude-Project=your-project-slug
```

Use the header names and project slug required by your account; the API key is
secret. A local receiver acknowledgement proves local OTLP delivery only, not
remote ingestion or persistence. For an opt-in acceptance against the real
pinned OpenTelemetry Collector (no model credentials required), run
`nix-shell shell.nix --run 'mise run test-integration-otel-collector'` from the
repository root. It exercises both routes in buffered and streaming modes and
validates the Collector file export, including parentage, usage/cost, and
metadata-only privacy. This verifies local Collector delivery, not deployed
Latitude grouping, accounting, or persistence.

The host uses parent-based sampling with 100% root sampling for accounting:
new roots are sampled, while valid parent sampling decisions are honored. Do not
force a backend-wide sampling policy to configure this host; set backend policy
for its own requirements.

For this subscription host, **bounded conversation capture is enabled by default**
(as requested for this setup). Prompts, instructions, and model responses can leave
this machine when export is enabled; treat traces as sensitive data. Set
`PIG_PROXY_CAPTURE_CONVERSATION=false` for metadata-only traces. The reusable
`pig_proxy` library still defaults to metadata-only. Projection is bounded and
omits unsupported content; it is not raw HTTP-body recording or a general PII
sanitizer. The subscriptions host opts in to the safe `otel_gleam_propagator_baggage`
propagator alongside Trace Context; this does not alter other Pig hosts. Proxy
tracing promotes only `session.id` and `gen_ai.conversation.id` baggage values.
Each supplied, validated identity is explicitly added to every proxy span for
that request, including server, logical inference and physical attempt spans;
baggage is not automatically converted to span attributes. Values are exact and
bounded: invalid, oversized, or U+FFFD-containing values (including replacement
characters produced while decoding malformed UTF-8) are rejected rather than
truncated. Other baggage is never copied to spans, and outbound baggage is
stripped. Review the
[capture/privacy contract](../../../../knowledge/OPENTELEMETRY_CONTENT_CAPTURE.md).

The host's default directional budgets are input 4 MiB source / 2 MiB serialized
content and output 4 MiB source / 64 KiB serialized content. Override them with
positive decimal integers, each independently bounded by 4 MiB for source and
2 MiB for serialized content. These conversation-capture budgets are separate
from the metadata SSE framer's 4 MiB per-event limit: an oversized event is
skipped through its delimiter so later events can still supply metadata, while
events above that finite limit are not parsed. A small cumulative capture budget
can omit conversation content without suppressing completion usage or response-ID metadata.

| Setting | Default | Maximum |
| --- | ---: | ---: |
| `PIG_PROXY_CAPTURE_INPUT_SOURCE_BYTES` | 4,194,304 | 4,194,304 |
| `PIG_PROXY_CAPTURE_INPUT_CONTENT_BYTES` | 2,097,152 | 2,097,152 |
| `PIG_PROXY_CAPTURE_OUTPUT_SOURCE_BYTES` | 4,194,304 | 4,194,304 |
| `PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES` | 65,536 | 2,097,152 |

Invalid values fail host configuration even when conversation capture is
switched off. The exporter adapter processes SDK batches sequentially and sends
at most four spans per OTLP request, preserving span and resource records. Four
is a count heuristic: input and output content limits can each reach 2 MiB, so
four spans can approach 16 MiB of content; eight could reach 32 MiB before
encoding overhead. This leaves headroom against the 32 MiB ingestion default
inspected in Latitude source, though that service limit is not independently
verified. The bound is on span count, not encoded request bytes.

The default batch processor queue is finite (2,048 spans). For standard
processors using the wrapped official exporter, the host applies a minimum
300,000 ms export-attempt deadline; this is not a per-request HTTP timeout.
The pinned exporter does not support `OTEL_EXPORTER_OTLP_TIMEOUT` or
`OTEL_EXPORTER_OTLP_TRACES_TIMEOUT`. These variables must not be confused with
SDK processor/export deadlines. User-supplied queue sizes are retained and can
exceed 2,048 (or be unbounded with `infinity`), and transport stalls can still
outlast shutdown deadlines. Failed batches
are dropped, not retried. The host's 15-second SDK-stop deadline and 30-second
overall shutdown watchdog are shorter, so shutdown flush is best effort and
cannot promise draining a full queue. Configured processor pipelines and
options are retained; official OTLP exporter entries on standard batch/simple
processors are wrapped, while non-OTLP exporters and custom processors are left
unchanged.

OTLP export is best effort. The pinned exporter drops failed batches rather than
retrying failed HTTP responses; monitor exporter diagnostics. Graceful shutdown
attempts a final SDK stop/flush, but cannot promise queue drain or remote
persistence.

Discover the configured models with:

```sh
curl http://127.0.0.1:8080/v1/models
```

The endpoint returns an OpenAI-compatible `object: "list"` with one entry per
unique model ID from both model lists, in configuration order. Entries include
`id`, `object: "model"`, `created: 0` (timestamp unknown), and `owned_by`
(`openai` or `zai`). Discovery is local: no upstream calls, credentials or base
URLs in the response, and no subscription entitlement check. It does not imply
that a ChatGPT model supports Chat Completions; the API restrictions below still
apply.

Clients must call raw upstream-compatible `/v1/responses` or
`/v1/chat/completions` and use `stream: true` for streaming. For Responses,
the Codex backend expects `store: false`, `stream: true`, and an `instructions`
string; send upstream-compatible input items. A Responses-capable client is
required: no translation to Chat Completions occurs.
For example, using the exact IDs configured in your model lists:

```sh
curl --no-buffer http://127.0.0.1:8080/v1/responses \
  -H 'content-type: application/json' \
  -d '{"model":"YOUR_CHATGPT_MODEL_ID","store":false,"stream":true,"instructions":"Be concise.","input":[{"role":"user","content":[{"type":"input_text","text":"Say hello"}]}]}'

curl --no-buffer http://127.0.0.1:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"YOUR_ZAI_MODEL_ID","stream":true,"messages":[{"role":"user","content":"Say hello"}]}'
```

The proxy preserves provider request bodies except its existing Chat Completions
stream-usage handling. Unknown or wrong-API model routes return 503 without an
upstream attempt; missing or malformed models return 400.

Stop gracefully with SIGTERM: ingress is stopped first, then managed runtime
actors, then the SDK's blocking termination callback attempts the final queued
export. No asynchronous force_flush cast is issued immediately before SDK stop.
A 30-second host watchdog bounds the complete shutdown, with a separate
15-second SDK-stop deadline. Cleanup errors, SDK-stop worker failures and timeouts
exit nonzero with generic diagnostics, without printing exception values or
claiming trace delivery.
Ctrl-C/SIGINT uses the Erlang VM's default interrupt behavior, not this graceful
path. Other signal events delivered to the replacement handler are ignored;
SIGQUIT/SIGUSR1 do not retain the default VM handler's diagnostic actions.
The host exits after cleanup; it does not claim physical connection drain.

## Verification

Pure configuration, environment-policy and decoded-span verification tests
always run and make no network calls or credential reads:

```sh
mise run test-subscriptions
```

The script compiles the isolated Rebar exporter graph and Gleam host, then runs
Gleam unit tests without starting the SDK. To run the service, the launch script
uses bare `erl` rather than `gleam run`, ensuring exporter dependencies start
before SDK setup. Run the opt-in local host acceptance check with:

```sh
mise run test-integration-subscriptions
```

It launches the real host with synthetic Codex/z.ai credentials and two local
upstream HTTP fixtures. Model discovery checks every configured ID across both
providers (including multiple models per provider), provider ownership, JSON
content type, credential/URL exclusion, and zero upstream calls. Buffered and
SSE traffic is sent through both APIs;
tests check route paths, model/body forwarding, provider-specific bearer and
Codex account headers, Chat-only stream usage injection, rejected requests and
zero upstream calls for validation/routing failures. SIGTERM must exit zero and
close the listener; missing and corrupt isolated auth files must fail startup.
A loopback OTLP receiver checks the standard trace endpoint/path, configured
headers, protobuf payload and `service.name`. It decodes and
acknowledges 26 spans per capture mode: 18 from successful requests and 8 from
rejections. Each export request must contain at most four spans, with no spans
lost across batches. Assertions cover span relationships, provider/model/API, response
IDs, finish reasons, input/output/cache usage, and credential exclusion. Metadata
mode exports no conversation; the host's default capture mode includes fixture
prompts and responses for both APIs in buffered and SSE form. A refused exporter
endpoint must leave business requests and graceful shutdown working. The gate
delays the SDK's scheduled batch timer and asserts zero exports before SIGTERM,
so shutdown must deliver the observed spans. Standard endpoint and header settings are exercised through the host
configuration path. Protocol parsing rejects unsupported values. The local
receiver exercises uncompressed protobuf only; gzip and console-export behavior
are not covered. Local receiver
acknowledgement does not prove remote backend delivery. Isolated
child-VM probes also exercise SDK worker crashes, explicit SDK errors, hung SDK
stop, hung cleanup and secret-bearing exceptions; each must exit nonzero without
leaking its marker. Successful cleanup must remain alive past the shortened test
deadline, verifying that the watchdog is cancelled.

Lifecycle policy, acceptance orchestration, HTTP fixtures, the OTLP receiver and
span assertions are written in Gleam. Handwritten Erlang is limited to the
SDK/application and OS-signal adapter, plus test child-VM/platform primitives.
The receiver calls the existing generated protobuf decoder through FFI; decoding
its terms into typed spans and verifying their contract happen in Gleam.

A catalog-publication barrier verifies that HTTP ingress remains closed until
pricing is available; a catalog outage verifies the bounded startup fallback.
The separate `mise run test-integration-catalog` command runs local catalog retry,
readiness, and admission-snapshot tests without model calls.

No real credential file or external provider is used. The acceptance suite is
compiled with normal tests and prints an explicit skip unless
`PIG_RUN_SUBSCRIPTIONS_INTEGRATION=1` is set. Receiver acknowledgement proves
local OTLP delivery only, not remote backend ingestion or persistence; verify a
live deployment separately.
