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
point the pricing catalog at a loopback fixture. URLs must use HTTPS, or HTTP to
loopback, with no embedded credentials, query, or fragment. No model aliases
or request rewriting are performed. The host binds only to `127.0.0.1` (port
8080, optionally `PIG_PROXY_PORT`); there is no inbound authentication, so do
not expose it to an untrusted network.

## Latitude and conversation capture

For this subscription host, **bounded conversation capture is enabled by default**
(as requested for this setup). Prompts, instructions, and model responses can leave
this machine when export is enabled; treat traces as sensitive data. Set
`PIG_PROXY_CAPTURE_CONVERSATION=false` for metadata-only traces. The reusable
`pig_proxy` library still defaults to metadata-only. Projection is bounded and
omits unsupported content; it is not raw HTTP-body recording or a general PII
sanitizer. Review the [capture/privacy contract](../../../../knowledge/OPENTELEMETRY_CONTENT_CAPTURE.md).

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
clears conflicting `OTEL_*` settings inside bootstrap, even for direct invocation. This config is not evidence of
cloud delivery. Exporter 1.10.0 drops failed batches and does not retry Latitude
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
A 30-second host watchdog
bounds the complete shutdown; timeout exits nonzero without claiming trace delivery.
Ctrl-C/SIGINT uses the Erlang VM's default interrupt behavior, not this graceful
path. Other signal events delivered to the replacement handler are ignored;
SIGQUIT/SIGUSR1 do not retain the default VM handler's diagnostic actions.
The host exits after cleanup; it does not claim physical connection drain.

## Verification

Unit config tests always run and make no network calls or credential reads:

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
acknowledges 20 spans per capture mode: 12 from successful requests and 8 from
rejections. Assertions cover span relationships, provider/model/API, response
IDs, finish reasons, input/output/cache usage, and credential exclusion. Metadata
mode exports no conversation; the host's default capture mode includes fixture
prompts and responses for both APIs in buffered and SSE form. A refused exporter
endpoint must leave business requests and graceful shutdown working. The gate
delays the SDK's scheduled batch timer and asserts zero exports before SIGTERM,
so shutdown must deliver the observed spans. Conflicting OTEL endpoint, header,
protocol, compression, and console-export settings are injected into the child
process to verify that they cannot redirect or print captured content.

No real credential file or external provider is used. The acceptance suite is
compiled with normal tests and prints an explicit skip unless
`PIG_RUN_SUBSCRIPTIONS_INTEGRATION=1` is set. Receiver acknowledgement proves local
wire delivery, not Latitude cloud ingestion; check your project's Traces view on
the first live run.
