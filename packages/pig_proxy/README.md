# pig_proxy

An OpenRouter-style LLM proxy for the [`pig`](https://github.com/kasuboski/pig) agent
ecosystem. `pig_proxy` sits between your agents and an OpenAI-compatible upstream
(OpenAI, a local Ollama server, or the ChatGPT/Codex backend), and:

- Strips client-supplied credentials and injects the upstream key you configured
  (security perimeter — callers never see or send real API keys).
- Pipes Server-Sent Events (SSE) streaming responses through in real time,
  buffering only enough to track token usage across chunk boundaries.
- Retries transient upstream failures (429/500/502/503/504 and network errors)
  with exponential backoff, jitter, and `Retry-After` support.
- Routes exact API/model pairs to one configured upstream target and fails
  closed for unknown models, API mismatches, and ambiguous default targets.
- Emits `:telemetry` events for every request and exposes a Prometheus
  `/metrics` endpoint with per-model request, latency, token, and cost metrics
  (cost is computed from a live [models.dev](https://models.dev) catalog).

## Installation

Build or run the proxy directly from this repository's flake:

```sh
nix build github:kasuboski/pig#pig-proxy
nix run github:kasuboski/pig#pig-proxy
```

For development, `pig_proxy` can also be built and run from within this
monorepo. From the repo root:

```sh
mise install
cd packages/pig_proxy
gleam deps download
```

To use it as a library dependency in another Gleam project instead of running
it standalone:

```sh
gleam add pig_proxy
```

## Quick start (standalone server)

The simplest setup proxies to a local Ollama server with no real credentials:

```sh
cd packages/pig_proxy
gleam run
```

This starts the server on `127.0.0.1:8080` (default) forwarding to
`http://localhost:11434/v1` with an `ollama` placeholder key — no configuration
needed for local development.

Point it at a real OpenAI-compatible provider instead:

```sh
export OPENAI_COMPAT_BASE_URL="https://api.openai.com/v1"
export OPENAI_COMPAT_API_KEY="sk-..."
export PIG_PROXY_BIND=127.0.0.1
export PIG_PROXY_PORT=8080
gleam run
```

Then send requests to the proxy exactly as you would to the upstream:

```sh
curl http://localhost:8080/v1/chat/completions \
  -H "content-type: application/json" \
  -d '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"hi"}]}'
```

Any `authorization`/`api-key` header the client sends is discarded — the proxy
always injects its own configured credential upstream.

## Configuration

`pig_proxy.main()` builds its config from environment variables
(`pig_proxy/config.from_env`):

| Variable | Default | Purpose |
|---|---|---|
| `PIG_PROXY_BIND` | `127.0.0.1` | Address the proxy listens on. |
| `PIG_PROXY_PORT` | `8080` | Port the proxy listens on. |
| `OPENAI_COMPAT_BASE_URL` | `http://localhost:11434/v1` | Upstream base URL, including `/v1`. |
| `OPENAI_COMPAT_API_KEY` | `ollama` | Key injected as `Authorization: Bearer <key>` on every forwarded request (ignored when the target is Codex OAuth). |
| `OPENAI_COMPAT_CODEX` | unset | When truthy, marks the default target as ChatGPT/Codex OAuth; its live token is resolved from the credential vault. |
| `OPENAI_COMPAT_CODEX_TOKEN` | unset | Static Codex JWT that seeds the credential vault at startup; also marks the default target as Codex OAuth. |
| `PIG_PROXY_MODELS_DEV_URL` | `https://models.dev/api.json` | Catalog used to compute per-request USD cost in `/metrics`. |
| `PIG_PROXY_MODELS_REFRESH_MS` | `3600000` (1h) | How often the models.dev catalog is refreshed. |

`gleam run` from `packages/pig_proxy` calls `pig_proxy.main()`, which loads this
config, starts the metrics aggregator and model catalog refresher, and starts
the mist HTTP server.

### Endpoints

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/v1/chat/completions` | Proxied to upstream, streaming or sync depending on `"stream"` in the body. |
| `POST` | `/v1/responses` | Proxied to upstream's Responses API (also the Codex Responses route). |
| `GET` | `/v1/models` | OpenAI-compatible model discovery from explicitly configured strict routes. |
| `GET` | `/health` | Liveness probe — always `200 {"status":"ok"}`. |
| `GET` | `/metrics` | Prometheus text exposition of request/latency/token/cost metrics. |

### Model Discovery

`GET /v1/models` returns `{"object":"list","data":[...]}`. Each entry has
`id`, `object: "model"`, `created: 0` (timestamp unknown), and `owned_by`
(the configured provider, or `pig_proxy` when unknown). Model IDs are
unique and keep their first routable occurrence in configuration order;
that occurrence also supplies the provider ownership.

Only strict routes supported by the server and their target are advertised.
Default-target mode returns an empty list because it has no explicit finite
model inventory. Discovery never calls upstreams, reads credentials, or uses
the models.dev pricing catalog, and does not establish subscription entitlement.
Clients still need to select the correct API for each model.

```sh
curl http://127.0.0.1:8080/v1/models
```

## Codex / ChatGPT OAuth

The Responses route (`/v1/responses`) doubles as the route for OpenAI's Codex
subscription backend (`chatgpt.com/backend-api/codex/responses`), which
authenticates with a ChatGPT OAuth JWT rather than a platform API key.

`pig_proxy` can obtain and refresh Codex credentials itself through OpenAI's
OAuth endpoints — no external CLI required.

### Logging in

From the repository root:

```sh
mise run codex-login
```

(or, from inside the package: `cd packages/pig_proxy && gleam run -m pig_proxy/codex_login` — `gleam` needs the package's `gleam.toml`, so it must be run from `packages/pig_proxy`, not the repo root).

The standard flow prints a short device code. Open
`https://auth.openai.com/codex/device` in **any** browser, enter the code, and
`pig_proxy` polls for completion. It works unchanged on local machines,
remote servers, and headless hosts: no localhost callback, SSH tunnel, or
pasted redirect URL is needed. On completion it exchanges the authorization
code for tokens, extracts the `chatgpt_account_id` from the JWT, and persists
the credential pair to `~/.pig/codex_auth.json` (override the path with
`PIG_CODEX_AUTH_PATH`).

#### Optional browser callback

For local one-click login, use the same browser callback flow offered by the
Codex CLI and pi:

```sh
PIG_CODEX_LOGIN_BROWSER=1 mise run codex-login
```

This opens a callback server on `127.0.0.1:1455` and waits for the browser
redirect. It is only suitable when the browser can reach that local address;
use the standard device-code flow everywhere else.

### Starting the proxy

```sh
export OPENAI_COMPAT_BASE_URL="https://chatgpt.com/backend-api/codex"
gleam run
```

On startup `pig_proxy.main()` loads `~/.pig/codex_auth.json`, seeds the
credential vault with the stored access token, and starts a background refresh
actor (`pig_proxy/codex_refresh`) that checks expiry every 60 seconds and
proactively refreshes the access token 5 minutes before it expires. Refreshed
tokens are pushed into the vault (so in-flight requests pick them up
immediately via `vault.rotate_token`) and written back to disk.

### How it works

| Module | Responsibility |
|---|---|
| `pig_protocol/oauth/codex` | Pure PKCE/URL/token-building logic (no HTTP). |
| `pig_proxy/codex_credentials` | Disk persistence (`~/.pig/codex_auth.json`). |
| `pig_proxy/codex_login` | Interactive login: default device-code flow for local, remote, and headless hosts; optional local browser callback; token exchange and JWT account-id extraction. |
| `pig_proxy/codex_refresh` | Background actor: periodic expiry check, refresh, vault rotation, disk save. |
| `pig_proxy/vault` | In-memory credential store; `rotate_token` updates without restart. |
| `pig_proxy/proxy` | Header injection: uses `chatgpt-account-id` + `OpenAI-Beta` headers when `codex_token` is present. |
| `pig_proxy/server` | `apply_live_credential` overlays vault credentials onto each outgoing request. |

### Environment variable fallback

If you already have a Codex JWT (e.g. from `codex login`), you can still pass
it via environment variables instead of running the login flow. Setting
`OPENAI_COMPAT_CODEX_TOKEN` marks the default target as Codex OAuth and seeds
the credential vault with the JWT (no refresh, since a static token carries no
refresh token):

```sh
export OPENAI_COMPAT_BASE_URL="https://chatgpt.com/backend-api/codex"
export OPENAI_COMPAT_CODEX_TOKEN="<your JWT>"
gleam run
```

To use persisted credentials obtained via `pig_proxy/codex_login` instead, just
declare the target as Codex without a token:

```sh
export OPENAI_COMPAT_BASE_URL="https://chatgpt.com/backend-api/codex"
export OPENAI_COMPAT_CODEX=true
gleam run
```

Treat the JWT like a password — anyone holding it can act as your ChatGPT
account. Never commit it or log it.

## Nix package and NixOS service

### Standalone package

The flake exposes the proxy package and both executable entry points:

```sh
nix build github:kasuboski/pig#pig-proxy
nix run github:kasuboski/pig#pig-proxy
nix run github:kasuboski/pig#pig-proxy-login
```

The login executable defaults to the NixOS service credential path,
`/var/lib/pig-proxy/codex_auth.json`. For a standalone per-user installation,
select a writable path explicitly:

```sh
PIG_CODEX_AUTH_PATH="$HOME/.pig/codex_auth.json" \
  nix run github:kasuboski/pig#pig-proxy-login
```

### NixOS module

Import the flake module and enable the service:

```nix
{
  inputs.pig.url = "github:kasuboski/pig";

  outputs = { nixpkgs, pig, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        pig.nixosModules.pig-proxy
        {
          services.pig-proxy = {
            enable = true;
            codex = true;
            upstreamBaseUrl = "https://chatgpt.com/backend-api/codex";
          };
        }
      ];
    };
  };
}
```

The module runs as the `pig-proxy` system user and stores rotating Codex
credentials at `<stateDirectory>/codex_auth.json`. With the default
`stateDirectory`, this is `/var/lib/pig-proxy/codex_auth.json`. After activating
the service, log in with the packaged device-code flow:

```sh
sudo systemctl stop pig-proxy
sudo -u pig-proxy pig-proxy-login
sudo systemctl start pig-proxy
```

The login helper installed by the module follows its configured
`stateDirectory`, so no environment variable is needed even when it is
customized. Outside the NixOS service, the package-level executable defaults to
`/var/lib/pig-proxy/codex_auth.json`; override `PIG_CODEX_AUTH_PATH` when a
per-user path is preferred.

Static API keys must be supplied through a runtime environment file rather
than a Nix string, which would expose the secret in the Nix store:

```nix
services.pig-proxy.environmentFile = "/run/secrets/pig-proxy.env";
```

The file uses systemd environment syntax, for example
`OPENAI_COMPAT_API_KEY=sk-...`. It can be provisioned by sops-nix, agenix, or
another secret manager.

Common module options:

| Option | Default | Purpose |
|---|---|---|
| `services.pig-proxy.stateDirectory` | `/var/lib/pig-proxy` | Persistent credentials and service state. |
| `services.pig-proxy.bind` | `127.0.0.1` | Listening address. |
| `services.pig-proxy.port` | `8080` | Listening port. |
| `services.pig-proxy.upstreamBaseUrl` | `http://localhost:11434/v1` | OpenAI-compatible upstream URL. |
| `services.pig-proxy.provider` | `null` | Optional models.dev provider key for cost metrics. |
| `services.pig-proxy.codex` | `false` | Enable persisted ChatGPT/Codex OAuth credentials. |
| `services.pig-proxy.retriesPerTarget` | `1` | Additional attempts to the selected upstream target. |
| `services.pig-proxy.modelsDevUrl` | `https://models.dev/api.json` | Model and pricing catalog URL. |
| `services.pig-proxy.modelsRefreshMs` | `3600000` | Catalog refresh interval in milliseconds. |
| `services.pig-proxy.environmentFile` | `null` | Runtime secrets file outside the Nix store. |
| `services.pig-proxy.openFirewall` | `false` | Open the configured TCP port. |

`stateDirectory` accepts any absolute path. The module creates it with mode
`0700`, grants the hardened service write access, and uses it for credentials,
the service user's home, and the packaged login command. It can point directly
at persistent storage:

```nix
services.pig-proxy.stateDirectory = "/persist/pig-proxy";
```

Alternatively, an impermanence configuration can consume the default path as
the single value to persist:

```nix
environment.persistence."/persist".directories = [
  {
    directory = config.services.pig-proxy.stateDirectory;
    user = "pig-proxy";
    group = "pig-proxy";
    mode = "0700";
  }
];
```

## Programmatic configuration

For multiple upstreams, exact model routing, or API-specific targets, build
`ProxyConfig` directly instead of using `from_env`, then hand it to
`runtime.start` (which brings up the supervisor tree and returns the
`ServerState`) and `server.start`:

```gleam
import gleam/erlang/process
import pig_otel
import pig_proxy/config
import pig_proxy/runtime
import pig_proxy/server

pub fn main() {
  let openai =
    config.openai_target("openai", "https://api.openai.com/v1", "sk-...")

  let codex =
    config.codex_target("codex", "https://chatgpt.com/backend-api/codex")

  let cfg =
    config.new([openai, codex])
    |> config.with_routes([
      config.model_route(pig_otel.ChatCompletions, "gpt-4o", "openai"),
      config.model_route(pig_otel.Responses, "o3", "codex"),
    ])
    |> config.with_port(8080)
    |> config.with_retries_per_target(1)

  let state = runtime.start(cfg)
  server.start(state)
  process.sleep_forever()
}
```

`config.with_routes` installs exact API/model-to-target routes. Every strict
route must reference an existing target that supports that API, and an empty
route table is invalid. Configurations without explicit routes accept requests
only when exactly one target is configured. Retries may repeat attempts to the
selected target; the proxy does not advertise cross-provider fallback.

## OpenTelemetry

Both POST inference routes have server, logical GenAI, and physical HTTP attempt
spans in buffered and streaming mode. Metadata-only is the default. Opt eligible
proxy requests into bounded structured capture by supplying the shared policy to
`config.with_tracing`:

```gleam
import pig_otel
import pig_otel/content/options

let cfg =
  config.new(targets)
  |> config.with_tracing(pig_otel.Conversation(options.defaults()))
```

`pig.with_tracing` accepts the same policy and uses the same private
`pig_otel_content_ffi` decoder/redactor/limiting boundary for normalized protocol
input/output. The proxy uses that module for observed upstream JSON/SSE. This
removes duplicated projection logic and fixtures, not OTP lifecycle ownership:
Pig owns run/inference/tool spans, while the proxy owns server/logical/attempt
spans and stream workers. Capture is not raw-body recording and does not alter
upstream/downstream payloads or translate Responses requests to Chat Completions.
See the [conversation capture guide](../../knowledge/OPENTELEMETRY_CONTENT_CAPTURE.md)
for projection, limits, synchronous capture overhead, and privacy requirements.
The embedded library does not start an SDK/exporter. The host must configure the official composite
Trace Context/Baggage propagator and disable overlapping HTTP auto-instrumentation
for proxy-owned sends. Baggage is stripped; duplicate propagation headers are
scrubbed before explicit-context injection.

`config.with_tracing(cfg, pig_otel.Disabled)` creates no Pig spans or tracer lookup,
but preserves sanitized explicit-parent propagation. Since there is only one
tracing-policy builder, the last call replaces the previous policy.
Health/metrics/unmatched routes and pre-handler HTTP rejection are not traced.
Body-read rejection on the
two inference routes is traced.

Temporary supervised owners hold stream spans across request retirement. The
physical attempt ends on upstream terminal, the logical span ends after incremental
metadata finalization, and the server span ends on downstream application terminal.
Buffered server completion is response construction. Streaming server completion
excludes Mist's private terminating-chunk write; neither claims wire-delivered
completion. Stop HTTP ingress, call `pig_proxy/runtime.stop(state)` for states
returned by `runtime.start`, then flush/stop the host SDK. This acknowledges
supervised cancellation cleanup, not successful completion or physical connection
drain. Manually assembled states with `supervisor: None` remain host-managed.
Owner hard kill/VM death cannot guarantee span delivery.

Metric emitters explicitly carry each runtime's trusted identity policy and named
catalog snapshot, independently of tracing, with unknown sentinels for untrusted
labels. Rich typed audit events retain their original facts.

The [local host runbook](../pig_otel/examples/local_validation/README.md) needs no
model credentials. See the [validation runbook](../../knowledge/OPENTELEMETRY_VALIDATION.md)
for official SDK recording, actual OTLP delivery, and the narrowly accepted
third-party Mist/Gramps warning policy.

## Observability

Every request emits typed `:telemetry` events (`pig_proxy/telemetry`):
`RequestStart`, `RequestStop`, `RequestError`, `StreamChunk`,
`CircuitStateChange`. The background metrics aggregator
(`pig_proxy/metrics`) attaches as a handler and exposes P50/P95/P99 latency,
request/error counts, bytes streamed, and token counts per model at
`/metrics`, in Prometheus text format:

```text
pig_proxy_requests_total{model="gpt-4o-mini"} 42
pig_proxy_latency_p95_ms{model="gpt-4o-mini"} 812
pig_proxy_cost_usd{model="gpt-4o-mini"} 0.003120
```

Cost is computed from live pricing pulled from models.dev
(`pig_proxy/model_catalog`), refreshed on the interval configured by
`PIG_PROXY_MODELS_REFRESH_MS` (one hour by default). The actor fetches once
immediately at startup. Successful fetches continue at that configured
interval; failed fetches retain the last-good catalog and retry with equal
jitter in `[half the exponential delay, the full delay]`: nominal caps grow
from 5s, 10s, 20s, and so on up to the configured interval. Runtime randomness
is used for each attempt so separate deployments do not share deterministic
retry timings. For HTTP 429/503 responses, a valid `Retry-After` delta-seconds
or HTTP-date is a minimum delay and can exceed the normal interval/backoff cap.
Any successful refresh resets the failure sequence.

## Development

From this package directory:

```sh
gleam test
gleam build --warnings-as-errors
```

From the repository root, build and test every package:

```sh
mise run build
mise run test
```

## License

Apache-2.0
