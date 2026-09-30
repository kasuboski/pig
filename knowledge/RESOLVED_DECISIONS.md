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

9. **Agent Identity Fields:** `AgentConfig` carries optional identity fields for rich session metadata. Direct tracing currently uses the configured agent name; it does not infer every `gen_ai.agent.*` attribute from these fields:
   - `agent_id`: Optional unique identifier
   - `agent_name`: Optional human-readable name
   - `agent_description`: Optional description of agent purpose
   - `agent_version`: Optional version string
   - `provider_name`: Optional provider identifier (e.g., `"openai"`, `"ollama"`)

   All fields default to `None` — they are opt-in and not required for basic usage.

10. **Observability Channels:** Rich audit events, lightweight operational measurements, and direct execution traces have separate owners:

    - **`SessionEvent`**: Typed events distributed by the dispatcher to session writers, terminal output, and custom audit consumers. These events can contain conversation and tool content.
    - **`:telemetry`**: Lightweight durations, counts, and metadata projected for BEAM ecosystem handlers. Tool arguments/results are not included; metric consumers must keep labels bounded.
    - **OpenTelemetry**: Metadata-only spans created and finalized by the live agent/proxy execution owners. The host owns SDK/exporter setup and shutdown. No telemetry-to-span bridge is installed.

11. **SessionEvent Canonicality:** `SessionEvent` is the canonical rich audit input, not the source of live OTel spans. The dispatcher projects lightweight telemetry and fans out full audit events. Direct tracing is independent and does not capture prompts/completions, even for non-streaming requests. See [OPENTELEMETRY.md](OPENTELEMETRY.md) for the implemented ownership and privacy contract.

12. **Thinking Levels:** Investigation found that the existing assistant `Thinking` field only stored provider output and `reasoning.encrypted_content` only requested replay data; neither configured reasoning effort. Reasoning effort is represented by the provider-neutral `ThinkingLevel` union (`Off`, `Minimal`, `Low`, `Medium`, `High`, `XHigh`, `Max`) in agent-owned inference settings. `Provider` is one argument, `InferenceRequest`, carrying messages, tools, and settings. An explicit `Off` differs from an unset setting, which allows the provider default. The setting can change mid-session and is durably restored. OpenAI Chat Completions maps it to `reasoning_effort`; Responses maps it to `reasoning.effort`. Pig does not maintain a model capability catalog or clamp levels, so provider APIs report unsupported values. Inference start/stop and setting changes are observable events.

---

## Observability Implementation

```text
agent runtime
  |-- SessionEvent -> dispatcher -> rich audit consumers
  |                         `----> lightweight :telemetry handlers
  `-- owned OTel spans -> official API -> host SDK/exporter

proxy execution owners
  |-- scoped metric emitter -> owning runtime's metrics
  `-- owned HTTP/GenAI spans -> official API -> host SDK/exporter
```

The pure agent state machine, protocol messages, and generic HTTP transport carry
no OTel policy or persistent trace handles. A process boundary requires explicit
context handoff; asynchronous audit delivery cannot supply the live operation's
terminal ownership. Normal audit fan-out is fire-and-forget; consumer registration
and graceful shutdown use acknowledged boundaries.

Use `:logger` only for internal diagnostics that telemetry does not already cover.
No raw tool arguments/results are projected into lightweight telemetry. Rich audit
consumers remain content-bearing and require their own storage/privacy policy.
Metric labels are bounded independently of span metadata.

The shared mappings and lifecycle boundaries are documented in
[OPENTELEMETRY.md](OPENTELEMETRY.md). Reproducible API-only, SDK recording, and
OTLP delivery checks are in [OPENTELEMETRY_VALIDATION.md](OPENTELEMETRY_VALIDATION.md).
