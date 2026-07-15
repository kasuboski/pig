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
- Resolves virtual model slugs to ordered fallback chains of upstream targets
  (`pig_proxy/routes`), filtered by tool/JSON-schema capability.
- Emits `:telemetry` events for every request and exposes a Prometheus
  `/metrics` endpoint with per-model request, latency, token, and cost metrics
  (cost is computed from a live [models.dev](https://models.dev) catalog).

## Installation

`pig_proxy` is built and run from within this monorepo. From the repo root:

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

This starts the server on `:8080` (default) forwarding to
`http://localhost:11434/v1` with an `ollama` placeholder key — no configuration
needed for local development.

Point it at a real OpenAI-compatible provider instead:

```sh
export OPENAI_COMPAT_BASE_URL="https://api.openai.com/v1"
export OPENAI_COMPAT_API_KEY="sk-..."
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
| `GET` | `/health` | Liveness probe — always `200 {"status":"ok"}`. |
| `GET` | `/metrics` | Prometheus text exposition of request/latency/token/cost metrics. |

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
| `pig_proxy/codex_login` | Interactive login: mist callback server, code exchange, JWT account-id extraction. |
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

## Programmatic configuration

For multiple upstreams, virtual model routing, or fallback chains, build a
`ProxyConfig` directly instead of using `from_env`, then hand it to
`runtime.start` (which brings up the supervisor tree and returns the
`ServerState`) and `server.start`:

```gleam
import gleam/erlang/process
import pig_proxy/config
import pig_proxy/runtime
import pig_proxy/server

pub fn main() {
  let openai =
    config.openai_target("openai", "https://api.openai.com/v1", "sk-...")
    |> config.with_fallback("gpt-4o-mini")

  let ollama =
    config.openai_target("ollama", "http://localhost:11434/v1", "ollama")

  let cfg =
    config.new([openai, ollama])
    |> config.with_port(8080)
    |> config.with_retries_per_target(1)

  let state = runtime.start(cfg)
  server.start(state)
  process.sleep_forever()
}
```

Slug-based routing with fallback chains lives in `pig_proxy/routes`:

```gleam
import pig_proxy/routes

let routes = [
  routes.route_with_fallbacks("smart-model", "openai", ["ollama"]),
]
```

A request for `"model": "smart-model"` resolves to `openai` first;
`routes.filter_by_capability` further narrows the chain by whether the request
needs tool calls or strict JSON schema support.

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
`PIG_PROXY_MODELS_REFRESH_MS`.

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
