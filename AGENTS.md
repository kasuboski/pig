A Gleam library for building and orchestrating agents on the BEAM. `pig` is inspired by the architecture of [pi](https://pi.dev).

High-Level Goals
*   **Composition over Configuration:** Build specialized agents by composing discrete skills and tools.
*   **Provider Agnostic:** Normalize interactions across OpenAI, Anthropic, and local models.
*   **Resilient by Default:** Leverage OTP supervision trees to ensure tool failures or API timeouts don't crash the system.
*   **Deep Observability:** Native integration with BEAM `:telemetry` for world-class tracing and debugging.
*   **Target BEAM:** No javascript platform is necessary

No backwards compatibility is necessary - use the latest versions and NO deprecated methods.


Code Quality:
- Fix compiler warnings — zero warnings is the baseline
- Prefer union types over multiple related types — a single `Event` custom type with variants
  is better than six separate `FooMeta` record types. It gives exhaustiveness checking,
  pattern matching, and single-function APIs (`emit(Event)` not `emit_foo(FooMeta)`).
- Make illegal states unrepresentable — if a combination of fields shouldn't exist,
  the type system should prevent constructing it.
- Types should encode intent — a type named `Event` with `ToolStart` and `InferenceStop`
  variants is self-documenting; `Dict(String, String)` is not.

Related project knowledge can be found in the knowledge folder. Use this before trying to search the web.
- SPEC.md includes a high level specification of what we are building
- TESTING_STRATEGY.md includes the testing strategy for the project that MUST be followed.
- GLEAM_OVERVIEW.md is the entire gleam language tour site.
- repos/ includes git repos that provide reference e.g. the pi-mono repo is there.


## Observability: Telemetry vs Logging

**Two channels, two audiences. Never duplicate information across both.**

| | `:telemetry` (`pig/obs`) | `:logger` (`logging`) |
|---|---|---|
| Audience | Library users (JSONL, OTel, dashboards) | Library developers (us, debugging pig internals) |
| What | Structured events: `[:pig, :inference, :stop]` with measurements + metadata | Freeform text: HTTP transport details, config validation, internal state |
| Where | `pig/obs/events.gleam` emits; `pig/obs/terminal` and `pig/obs/session` consume | Any module, for gaps telemetry doesn't cover |
| Visibility | User-facing, always-on when handlers attached | Off by default, enabled via log level |

**Rules:**
- If telemetry covers it (inference, tool execution), do NOT also log it.
- `:logger` is for gaps: HTTP transport debugging, unexpected states, config warnings.
- `pig/obs/terminal` is a telemetry handler, not a logger.

## Logging Usage

Use the `logging` package for internal debug logging. Examples:
```gleam
import logging

logging.debug("HTTP POST /v1/chat/completions -> 429, retrying")
logging.warning("Config has no base_url, using default")
logging.error("Provider returned malformed JSON")
```
