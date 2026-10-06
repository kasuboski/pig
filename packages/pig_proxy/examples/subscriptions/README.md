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
service, so do not attach untrusted containers. Latitude remains opt-in, and the
same sensitive-conversation capture warning applies.

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

## Latitude and conversation capture

For this subscription host, **bounded conversation capture is enabled by default**
(as requested for this setup). Prompts, instructions, and model responses can leave
this machine when export is enabled; treat traces as sensitive data. Set
`PIG_PROXY_CAPTURE_CONVERSATION=false` for metadata-only traces. The reusable
`pig_proxy` library still defaults to metadata-only. Projection is bounded and
omits unsupported content; it is not raw HTTP-body recording or a general PII
sanitizer. Review the [capture/privacy contract](../../../../knowledge/OPENTELEMETRY_CONTENT_CAPTURE.md).

The host's default directional budgets are input 4 MiB source / 2 MiB serialized
content and output 4 MiB source / 64 KiB serialized content. Override them with
positive decimal integers, each independently bounded by 4 MiB for source and
2 MiB for serialized content. These conversation-capture budgets are separate
from the metadata SSE framer's 4 MiB per-event limit: an oversized event is
skipped through its delimiter so later events can still supply metadata, while
events above that finite limit are not parsed. A small cumulative capture budget
can omit conversation content without suppressing completion usage or identity.

| Setting | Default | Maximum |
| --- | ---: | ---: |
| `PIG_PROXY_CAPTURE_INPUT_SOURCE_BYTES` | 4,194,304 | 4,194,304 |
| `PIG_PROXY_CAPTURE_INPUT_CONTENT_BYTES` | 2,097,152 | 2,097,152 |
| `PIG_PROXY_CAPTURE_OUTPUT_SOURCE_BYTES` | 4,194,304 | 4,194,304 |
| `PIG_PROXY_CAPTURE_OUTPUT_CONTENT_BYTES` | 65,536 | 2,097,152 |

Invalid values fail host configuration even when conversation capture is
switched off. When Latitude export is enabled, a subscription-host exporter
adapter traverses each SDK export batch and sends at most four spans in each
OTLP request. The adapter preserves the span and resource records, and leaves
the SDK queue capacity and scheduled export timing unchanged. Four is chosen
because configurable input and output content limits can each reach 2 MiB;
four spans can approach 16 MiB of captured content, leaving headroom against
the 32 MiB ingestion default in the inspected Latitude source. Eight spans could
reach 32 MiB before encoding overhead. The hosted service's configured limit is
not independently verified. This is a span-count bound, not a strict encoded
request-byte bound.

Latitude export is disabled unless `PIG_LATITUDE_ENABLED=true`. Configure it before
starting the host:

```sh
export PIG_LATITUDE_ENABLED=true
export LATITUDE_API_KEY="..."
export LATITUDE_PROJECT="your-project-slug"
mise run run-subscriptions
```

Both `LATITUDE_API_KEY` and `LATITUDE_PROJECT` are required when enabled. The
default endpoint is `https://ingest.latitude.so/v1/traces`; override it with
`PIG_LATITUDE_ENDPOINT` for a local receiver. The host sets OTLP/HTTP protobuf,
no compression, and the authorization/project headers directly; it deliberately
clears conflicting `OTEL_*` settings before SDK/exporter startup, even for direct
invocation. This config is not evidence of cloud delivery. Exporter 1.10.0 drops failed batches and does not retry Latitude
429/503 responses or honor their Retry-After headers. Monitor exporter diagnostics;
shutdown flush is best effort and does not prove remote persistence.

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
A loopback OTLP receiver checks the exact `/v1/traces` path, fake Latitude auth
and project headers, uncompressed protobuf, and `service.name`. It decodes and
acknowledges 26 spans per capture mode: 18 from successful requests and 8 from
rejections. Each export request must contain at most four spans, with no spans
lost across batches. Assertions cover span relationships, provider/model/API, response
IDs, finish reasons, input/output/cache usage, and credential exclusion. Metadata
mode exports no conversation; the host's default capture mode includes fixture
prompts and responses for both APIs in buffered and SSE form. A refused exporter
endpoint must leave business requests and graceful shutdown working. The gate
delays the SDK's scheduled batch timer and asserts zero exports before SIGTERM,
so shutdown must deliver the observed spans. Conflicting OTEL endpoint, header,
protocol, compression, and console-export settings are injected into the child
process to verify that they cannot redirect or print captured content. Isolated
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
`PIG_RUN_SUBSCRIPTIONS_INTEGRATION=1` is set. Receiver acknowledgement proves local
wire delivery, not Latitude cloud ingestion; check your project's Traces view on
the first live run.
