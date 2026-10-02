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

Conversation capture is metadata-only by default. Set
`PIG_PROXY_CAPTURE_CONVERSATION=true` to opt into bounded conversation
projection. Content can include prompts and model responses; handle traces as
sensitive data. Latitude export is disabled unless `PIG_LATITUDE_ENABLED=true`.
When enabled, both `LATITUDE_API_KEY` and `LATITUDE_PROJECT` are required. The
default endpoint is `https://ingest.latitude.so/v1/traces`; override it with
`PIG_LATITUDE_ENDPOINT` for a local receiver. The host sets OTLP/HTTP protobuf,
no compression, and the authorization/project headers directly; it deliberately
does not inherit conflicting `OTEL_*` settings. This config is not evidence of
cloud delivery. Exporter 1.10.0 drops failed batches and does not retry Latitude
429/503 responses or honor their Retry-After headers. Monitor exporter diagnostics;
shutdown flush is best effort and does not prove remote persistence.

Clients must call raw upstream-compatible `/v1/responses` or
`/v1/chat/completions` and use `stream: true` for streaming. For Responses,
the Codex backend expects `store: false`, `stream: true`, and an `instructions`
string; send upstream-compatible input items. A Responses-capable client is
required: no translation to Chat Completions occurs.
The proxy preserves provider request bodies except its existing stream usage
handling. Stop gracefully with SIGTERM: ingress is stopped first, then managed
runtime actors, then the SDK is flushed and stopped. A 30-second host watchdog
bounds the complete shutdown; timeout exits nonzero without claiming trace delivery.
Ctrl-C/SIGINT uses the Erlang VM's default interrupt behavior, not this graceful
path. The host exits after cleanup; it does not claim physical connection drain.

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

It uses synthetic Codex/z.ai credentials and loopback-only configuration; it
does not use real credential files or call external providers. The acceptance
suite is compiled with normal tests and prints an explicit skip unless
`PIG_RUN_SUBSCRIPTIONS_INTEGRATION=1` is set.
