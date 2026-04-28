# Resolved Architectural Decisions

This document captures the key architectural decisions and implementation choices made during the planning phase for the `pig` library. These decisions are concrete commitments that guide implementation and are not covered in the high-level architecture specification (SPEC.md) or testing strategy (TESTING_STRATEGY.md).

---

## Resolved Decisions

1. **HTTP Stack:** Use `gleam_http` + `gleam_httpc` for all provider API calls, encapsulated in a thin wrapper module `pig/ai/http.gleam`. This provides a single point of change for HTTP client swapping in the future. The `logging` package is used for internal developer diagnostics only (request URLs, response statuses, timing), not for user-facing observability.

2. **Streaming Support:** Deferred to a future phase. The v1 provider interface is request/response only. Streaming responses (for tokens-as-they-arrive) will be added after the base implementation is stable.

3. **Middleware Layer:** Deferred until we have a working base. While the system design allows for middleware (e.g., safety guards, request transformers), the explicit middleware API will be implemented after core functionality is proven.

4. **Session Stores:** JSONL file-based storage only for v1. The session persistence system writes line-delimited JSON to a file for replay and debugging. Future versions may support alternative backends (Postgres, Redis, custom APIs), but the v1 contract is file-only.

5. **Supervisor API:** Export `pig.start_supervised(config)` as the primary, easy-start path for users. However, every component (agent, session writer, terminal printer) must also be startable standalone via `pig.start(config)` for advanced users who need custom supervision tree layouts.

6. **Target Platform:** Erlang only. Set `target = "erlang"` in `gleam.toml`. No JavaScript support is planned for v1.

7. **Provider v1 Scope:** OpenAI-compatible API only. The initial provider implementation uses the OpenAI Chat Completions format with a configurable `base_url` and arbitrary `model` string, enabling compatibility with Ollama, Together, Groq, and other OpenAI-compatible services. Anthropic provider support is explicitly deferred beyond v1.

8. **Provider Return Type:** The `Provider` type alias returns `Result(InferenceResult, AiError)`, not the simpler `Result(Message, AiError)`. The `InferenceResult` record wraps the `Message` with `InferenceMetadata` containing:
   - `response_id`: The provider's response identifier (e.g., `"chatcmpl-9J3u..."`)
   - `response_model`: The actual model used (may differ from request)
   - `finish_reason`: Why generation stopped (`"stop"`, `"tool_calls"`, `"length"`, etc.)
   - `input_tokens` and `output_tokens`: Token usage counts

   This ensures session persistence and future OpenTelemetry integration have access to provider response metadata without re-parsing or restructuring.

9. **Agent Identity Fields:** `AgentConfig` carries optional identity fields that populate OTel `gen_ai.agent.*` attributes and session headers:
   - `agent_id`: Optional unique identifier
   - `agent_name`: Optional human-readable name
   - `agent_description`: Optional description of agent purpose
   - `agent_version`: Optional version string
   - `provider_name`: Optional provider identifier (e.g., `"openai"`, `"ollama"`)

   All fields default to `None` — they are opt-in and not required for basic usage.

10. **Two-Channel Observability:** The library emits two independent, first-class event channels from the same code paths. Neither is a bridge or shim — both are canonical for their respective audiences:

    - **`SessionEvent`**: Rich, typed events sent directly to registered pig consumers (session writer, terminal printer, future OTel exporter). Carries full message content, tool arguments/results, token counts, and timing.
    - **`:telemetry`**: Lightweight metrics emitted via `telemetry.execute/3`. Follows the BEAM ecosystem standard, enabling zero-config integration with LiveDashboard, Telemetry.Metrics, `opentelemetry_telemetry`, AppSignal, and other telemetry consumers. Carries durations, counts, and model names — not message content.

    Both channels are always emitted from the same code paths. This design gives pig users immediate observability via standard BEAM tools while providing the rich data needed for pig-specific tooling.

11. **SessionEvent Canonicality:** For all pig-specific observability modules (session writer, terminal printer, future OTel exporter), `SessionEvent` is the single source of truth. All pig observability modules read from `SessionEvent`s. The `:telemetry` channel serves the broader BEAM ecosystem and is not a replacement for `SessionEvent`.

---

## Observability Model — Two First-Class Channels + Logging

The library emits events through two independent channels, each serving a different ecosystem:

| | `SessionEvent` (pig consumers) | `:telemetry` (BEAM ecosystem) | `:logger` (`logging`) |
|---|---|---|---|
| **Audience** | pig-specific consumers | BEAM ecosystem tools (LiveDashboard, Telemetry.Metrics, `opentelemetry_telemetry`, AppSignal) | Library developers (internal debugging) |
| **Content** | Full message content, metadata, tool args/results, token counts | Lightweight metrics (counts, durations, token counts, model name) | Freeform debug text |
| **Examples** | `InferenceCompleted(message, input_messages, token_counts)` | `[:pig, :inference, :stop]` with `%{duration_ms: 150}` | `[debug] pig/ai/http: POST /v1/chat/completions -> 429, retrying` |
| **Transport** | Gleam actor messages (fan-out to registered consumers) | `telemetry.execute/3` (broadcast) | Erlang `:logger` |
| **Consumers** | `pig/obs/session`, `pig/obs/terminal`, future `pig/obs/otel` | Any `:telemetry` handler in the BEAM ecosystem | Console, dev-time log files |
| **Visibility** | User-facing, on when consumers are registered | Always emitted — zero-config for BEAM users | Off by default |
| **Why it exists** | OTel GenAI semantics need full message bodies; pig-specific tooling needs full content | BEAM standard — Phoenix, Ecto, Oban all emit `:telemetry`. Users with existing dashboards get pig metrics for free. | Internal diagnostics only |

### Golden Rule: Two First-Class Channels, Zero Duplication

- `SessionEvent` carries full content (messages, tool args/results, token counts, timing). All pig-specific consumers read from it.
- `:telemetry` carries lightweight metrics (durations, counts, model name). BEAM ecosystem tools consume it natively.
- Both are always emitted from the same code paths. Neither is optional or a shim.
- `:logger` (via the `logging` package) is for internal developer diagnostics only: HTTP transport debugging, configuration validation warnings.
- Never duplicate data across channels. If `SessionEvent` covers it, don't also log it.

---

## OTel GenAI Semantic Conventions Coverage

The enriched types (`InferenceResult`, `AgentConfig` identity fields) and `SessionEvent` ensure we capture everything needed for future `pig/obs/otel` implementation. Since OTel needs full message bodies (`gen_ai.input.messages`, `gen_ai.output.messages`), the OTel exporter will read from `SessionEvent`s — the same canonical source as the session writer.

| OTel Attribute | Source | Available After |
|---------------|--------|----------------|
| `gen_ai.operation.name` | Hardcoded `"chat"` | Already |
| `gen_ai.provider.name` | `AgentConfig.provider_name` | Task 9.0d |
| `gen_ai.request.model` | `AgentConfig.model` | Already |
| `gen_ai.response.id` | `InferenceMetadata.response_id` → `SessionEvent` | Task 9.0a |
| `gen_ai.response.model` | `InferenceMetadata.response_model` → `SessionEvent` | Task 9.0a |
| `gen_ai.response.finish_reasons` | `InferenceMetadata.finish_reason` → `SessionEvent` | Task 9.0a |
| `gen_ai.usage.input_tokens` | `InferenceMetadata.input_tokens` → `SessionEvent` | Task 9.0a |
| `gen_ai.usage.output_tokens` | `InferenceMetadata.output_tokens` → `SessionEvent` | Task 9.0a |
| `gen_ai.input.messages` | `SessionEvent.InferenceCompleted.input_messages` | Task 9.1 |
| `gen_ai.output.messages` | `SessionEvent.InferenceCompleted.message` | Task 9.1 |
| `gen_ai.system_instructions` | `SessionEvent.SessionStarted.system_prompt` | Task 9.1 |
| `gen_ai.agent.id` | `AgentConfig.agent_id` → `SessionEvent` | Task 9.0d |
| `gen_ai.agent.name` | `AgentConfig.agent_name` → `SessionEvent` | Task 9.0d |
| `gen_ai.agent.description` | `AgentConfig.agent_description` → `SessionEvent` | Task 9.0d |
| `gen_ai.agent.version` | `AgentConfig.agent_version` → `SessionEvent` | Task 9.0d |
| `server.address` | Parse from `OpenAIConfig.base_url` | Already |
| `server.port` | Parse from `OpenAIConfig.base_url` | Already |
| `error.type` | `AiError` variant + detail → `SessionEvent.InferenceFailed` | Task 9.0a |

**Deferred (not needed for v1 session persistence):**
- `gen_ai.request.max_tokens`, `gen_ai.request.top_p`, `gen_ai.request.temperature` — request parameters not currently exposed. Add when building OTel exporter.

---

## Event Distribution Architecture

The agent emits two types of event for each significant action — a rich `SessionEvent` and a lightweight `:telemetry` event — from the same code paths.

### SessionEvent Channel (pig consumers)

```
pig/agent/core.gleam
  ↓ emits SessionEvent (fan-out to all registered consumers)
  ↓
  ├── pig/obs/session  (JSONL writer — full content)
  ├── pig/obs/terminal (pretty printer — lightweight fields)
  └── future pig/obs/otel (OTel GenAI semantics — full messages + spans)
```

### :telemetry Channel (BEAM ecosystem)

```
pig/obs/events.gleam
  ↓ emits [:pig, inference, :stop] etc. via telemetry.execute/3
  ↓
  └── ANY BEAM TELEMETRY CONSUMER (LiveDashboard, Telemetry.Metrics,
      opentelemetry_telemetry, AppSignal, custom handlers)
```

### Consumer Registration

- The agent's `AgentConfig` holds a `List(Subject(SessionEvent))` of registered consumers.
- `pig.with_session_writer(config, path)` creates a session writer actor and registers its `Subject`.
- `pig.with_terminal_output(config)` creates a terminal printer actor and registers its `Subject`.
- On each event, the agent iterates the list and sends to each consumer. A crashed consumer is silently skipped (it's supervised separately).
- `:telemetry` events are always emitted — no registration needed (standard BEAM behavior).

### Non-Blocking Delivery

The agent never blocks on event delivery — all sends are fire-and-forget (`actor.send`, not `actor.call`). This ensures that observability infrastructure issues never slow down or crash the agent execution loop.
