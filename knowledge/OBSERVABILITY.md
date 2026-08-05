# Observability Architecture

pig uses a **dispatcher-actor pattern** for all observability. The runtime interpreter (`runtime.gleam`) emits typed `SessionEvent` values to a single dispatcher actor. The dispatcher always projects lightweight telemetry to the BEAM `:telemetry` library, then fans out the full event to registered consumers.

The pure core (`update.gleam`) has **zero knowledge** of observability — it never imports the emit module, never touches a dispatcher subject, never fires telemetry. All event production happens in the runtime as it interprets effects and applies hooks.

---

## 1. Design Goals

- **Core is observation-free by construction** — `update.gleam` has no imports for telemetry, dispatchers, or event types. Events are a runtime concern.
- **Telemetry always-on by construction** — built into the dispatcher handler, not a registration convention.
- **Structured data for pig consumers** — full typed `SessionEvent` variants for session writer, terminal, OTel.
- **Lightweight projection for BEAM ecosystem** — flat metrics via `:telemetry` for LiveDashboard, AppSignal, etc.
- **Dynamic consumer registration** — consumers can attach and detach at runtime.
- **Independent consumer lifecycles** — a crashed consumer doesn't affect the dispatcher or other consumers.
- **Observability is optional and safe** — when no dispatcher is configured, all emission is a silent no-op. The agent never crashes due to missing telemetry.

---

## 2. Architecture

The system has four layers: the runtime interpreter that produces events, a thin `emit` module that wraps the send, the dispatcher actor that distributes them, and the consumers that process them.

```text
Runtime Interpreter (runtime.gleam)
  │
  ├── emit.to_dispatcher(dispatcher_subject, SessionEvent)
  │     └── wraps process.send to dispatcher actor
  │
  Dispatcher Actor (dispatcher.gleam)
  │
  ├── emit_telemetry(event)            // ALWAYS: lightweight metrics projection
  │     └── :telemetry.execute(...)    //   to BEAM ecosystem
  │
  └── fan-out to registered consumers  // fire-and-forget process.send
        ├── session writer   → JSONL file
        ├── terminal printer → stdout
        └── future OTel      → OpenTelemetry spans
```

### Dispatcher resolution

`RuntimeConfig` (held by the runtime actor) carries the dispatcher reference as either a direct `Subject` or a `Name`. The runtime resolves a name to a subject once per call via `process.named_subject`. This supports both start modes: the standalone path wires a `Subject` directly, while the supervised path wires a `Name` (because the dispatcher subject doesn't exist until the supervisor starts it).

When neither field is set — no dispatcher configured at all — every `emit_*` helper returns `Nil` without sending. This makes telemetry truly optional: an agent without observability configured runs identically to one with it, just silently.

### The emit module

`pig/obs/emit.gleam` exists to break the circular import between `events.gleam` and `dispatcher.gleam`. It provides `to_dispatcher(subject, event)` — a thin wrapper around `process.send`. The runtime imports this module rather than reaching into the dispatcher directly.

---

## 3. SessionEvent Type

`SessionEvent` is the single event type that flows through the system. It is defined in `pig/obs/events.gleam` and carries full structured data for every agent lifecycle event.

The variants are:

| Event | Purpose | Produced by |
|-------|---------|-------------|
| `SessionStarted` | Session begun with identity and model info | (reserved, not yet emitted) |
| `InferenceStarted` | Provider call beginning, with model, message count, and requested settings | `runtime` before provider call |
| `InferenceCompleted` | Provider call succeeded, with full message, tokens, timing, and requested settings | `runtime` after successful response |
| `InferenceFailed` | Provider call failed, with error details, timing, and requested settings | `runtime` after error |
| `InferenceSettingsChanged` | Durable agent setting changed | `runtime` after the setting is committed |
| `ToolStarted` | Tool execution beginning | `runtime` when executing tools |
| `ToolExecuted` | Tool execution finished, with result and timing | `runtime` after tool completion |
| `ToolBlocked` | Tool blocked by a hook | (reserved for hooks system) |
| `HookActed` | Hook performed an action | (reserved for hooks system) |
| `SessionEnded` | Session concluded, with reason | (reserved, not yet emitted) |

All inference and tool events carry duration measurements (in monotonic milliseconds), and the inference events carry token counts when available from the provider. Session lifecycle events (SessionStarted, SessionEnded) and hook events (HookActed) do not carry duration or tokens.

### Why "started" variants?

BEAM telemetry conventions use start/stop pairs for duration tracking. Tools like `Telemetry.Metrics` and `opentelemetry_telemetry` expect `[:pig, :inference, :start]` before `[:pig, :inference, :stop]`. Without the "started" events, the dispatcher can't emit the start-half of these pairs. Session consumers also benefit — the session writer can log "calling provider..." before the result arrives.

### Why the runtime produces events, not the core

In the sans-IO architecture, the pure core (`update.gleam`) returns `StepResult` values — `Done`, `Continue`, or `Failed`. The core knows *what* happened (a provider call is needed, tools need execution) but not *how* it happened. The runtime is the only layer that actually performs IO, measures duration, and observes outcomes — so it's the natural place to emit events.

This also means the core's test surface is tiny: `(state, msg) → StepResult`. No event assertions needed in core tests.

---

## 4. Telemetry Projection

The dispatcher emits BEAM `:telemetry` events as a built-in side effect of processing every `SessionEvent`. This is not optional — it happens by construction in the dispatcher's message handler, before any consumer fan-out.

The projection maps each `SessionEvent` to a flat telemetry event with string-keyed measurements and metadata:

| SessionEvent | Telemetry name | What's projected |
|-------------|---------------|-----------------|
| `InferenceStarted` | `[:pig, :inference, :start]` | model, message_count; metadata includes requested `thinking` |
| `InferenceCompleted` | `[:pig, :inference, :stop]` | model, duration, tokens (if present); metadata includes requested `thinking` and `stop_reason` (if present) |
| `InferenceFailed` | `[:pig, :inference, :exception]` | model, message_count; metadata includes error_type and requested `thinking` |
| `InferenceSettingsChanged` | *(session event only)* | durable requested settings |
| `ToolStarted` | `[:pig, :tool, :start]` | tool_name, tool_call_id, arguments_json |
| `ToolExecuted` | `[:pig, :tool, :stop]` | tool_name, tool_call_id, duration |
| `ToolBlocked` | `[:pig, :tool, :blocked]` | tool_name, tool_call_id, hook_name, reason |
| `SessionStarted` | *(not projected)* | — |
| `HookActed` | *(not projected)* | — |
| `SessionEnded` | *(not projected)* | — |

**Heavy fields stay out of telemetry.** Full message content, tool results, and input message lists are pig-consumer territory. In particular, `ToolExecuted.result` remains available to session consumers but is not included in telemetry metadata. Telemetry gets lightweight identifiers and metrics only. The `thinking` field is the requested setting, not an effective level reported by the provider; pig does not infer, clamp, or maintain model capabilities. This keeps `:telemetry` events cheap enough to fire on every agent step without impacting throughput.

The actual FFI call goes through `pig_obs_ffi.execute/3` (Erlang), which converts string-keyed dicts to atom-keyed maps and calls `:telemetry.execute/3`.

---

## 5. Consumers

### Built-in consumers

**Session writer** (`pig/obs/session.gleam`): appends each `SessionEvent` as a JSONL line to a file. Used for session replay and audit trails. The `format_event` function is a pure function that serializes any `SessionEvent` to JSON — testable without side effects.

**Terminal printer** (`pig/obs/terminal.gleam`): prints a human-readable one-line summary of each event to stdout. Also has a pure `format_event` function for testing.

### Consumer registration

Consumers register with the dispatcher by sending a `RegisterConsumer(Subject(SessionEvent))` message. The dispatcher adds the subject to its internal list and fans out all subsequent events to every registered consumer.

Registration happens in two ways:

1. **Automatic** — when using `start_supervised()` or `start()`, consumer specs accumulated on the config are started and registered as part of the startup sequence.
2. **Dynamic** — callers can register a `StartedConsumer` endpoint with the dispatcher at runtime. This is useful for mid-session debugging. Dynamically attached consumers are not supervised by the dispatcher.

### Dead consumer handling

The dispatcher delivers through `StartedConsumer` endpoints rather than knowing each actor's message protocol. Delivery to a dead BEAM process remains a no-op, so the dispatcher does not crash or need to detect dead consumers. Supervised endpoints resolve their named process on delivery and therefore survive consumer reconstruction. If pruning becomes necessary later, health tracking can be added at the endpoint boundary.

### Consumer specs

`pig/obs/consumer_spec.gleam` defines `ConsumerSpec` — a deferred recipe for starting a consumer. It bundles three things:

- `spec`: a `ChildSpecification(Nil)` for starting in a supervision tree
- `name`: a `Name(SessionEvent)` used by the supervised endpoint
- `start_fn`: a `fn() -> Result(StartedConsumer, StartError)` for the unsupervised start path

A `StartedConsumer` owns both event delivery and shutdown operations. This lets standalone startup roll back every process it has already acquired without exposing consumer-specific control messages to the dispatcher. Builder functions like `pig.with_session_writer(path)` accumulate `ConsumerSpec` values on the config. No actors are spawned at config-construction time — the builder is pure data.

---

## 6. Dispatcher Actor

The dispatcher (`pig/obs/dispatcher.gleam`) is a standard Gleam OTP actor. Its internal state is a list of consumer endpoints. It handles four messages:

- **`Event(SessionEvent)`** — emits telemetry, then fans out to all consumers. Always continues.
- **`RegisterConsumer(StartedConsumer)`** — asynchronously adds the endpoint.
- **`RegisterConsumerSync(StartedConsumer, Subject(Nil))`** — adds the endpoint and acknowledges registration.
- **`Stop`** — stops the actor.

The dispatcher is intentionally simple. It does not buffer events, does not retry failed sends, and does not track consumer health. This keeps it fast and crash-resistant — the agent never blocks on observability.

---

## 7. Two Start Modes

### Supervised (`pig/supervisor.gleam`)

`start_supervised(agent_config, dispatcher_name)` builds the runtime with a named dispatcher reference. The runtime resolves the name to a live subject on first emission.

```text
AppSupervisor (OneForOne)
  ├── EventSupervisor (OneForAll)
  │     ├── event_dispatcher (named)
  │     ├── session_writer (named)
  │     └── terminal_printer (named)
  └── pig_agent (named)
```

The dispatcher child is initialized with endpoints backed by each consumer's name. Because those endpoints resolve the current named process on every delivery, `OneForAll` reconstruction preserves registration without a post-start race.

**Error handling:** supervisor start failures are returned as `Error(StartError)`.

### Standalone (`pig.gleam`)

`pig.start(config)` starts the dispatcher and consumers individually, without a supervisor. The dispatcher subject is wired directly into `RuntimeConfig` as a `Subject`. Each consumer's `start_fn` returns an owned endpoint, and all endpoints are registered synchronously before the runtime starts.

**Error handling:** consumer acquisition short-circuits on the first failure. A consumer-start, registration, or runtime-start failure stops every consumer already acquired and then stops the dispatcher before returning the typed `StartError`. A successful `Agent` retains those owned handles so `pig.stop` also stops its runtime, consumers, and dispatcher.

---

## 8. Design Decisions

### Why dispatcher-name vs dispatcher-subject

`RuntimeConfig` accepts either a direct `Subject` or a `Name`. This is deliberate:

- The **standalone path** (`pig.start`) creates the dispatcher first, then passes the live `Subject` into the runtime config.
- The **supervised path** (`supervisor.start_supervised`) can't create the dispatcher first — it's started by the supervisor. Instead it passes a `Name`, and the runtime resolves it to a `Subject` via `process.named_subject` on each emission.

Both paths resolve to the same behavior: the runtime checks for a `Subject` first, falls back to resolving a `Name`, and skips emission entirely if neither is set.

### Why fire-and-forget, not request-response

All event sends from runtime to dispatcher, and from dispatcher to consumers, use `process.send` (asynchronous). The agent never waits for observability to complete. This guarantees that adding consumers or telemetry never slows down the agent loop.

### Why nested supervision, not flat

A flat `RestForOne` with dispatcher + consumers + agent as siblings means a consumer crash could cascade to the agent. The nested structure isolates crash domains: the event subtree restarts independently, the agent subtree is separate, and the top-level `OneForOne` keeps them completely isolated.

### Restart re-registration gap

With `OneForAll` inside the event subtree, if the dispatcher crashes, all consumers restart too. This ensures the dispatcher's fresh consumer list stays consistent. Consumer re-registration happens via the post-start loop in `start_supervised()`. The top-level `OneForOne` keeps the agent subtree completely isolated from the event subtree.

---

## 9. What This Enables

### Immediate
- **Session replay** — full structured JSONL with before/after events
- **Terminal output** — real-time formatted display of agent activity
- **Test assertions** — tests can register a capture consumer and assert on event sequences
- **BEAM ecosystem integration** — `:telemetry` events work with LiveDashboard, AppSignal, etc.

### Hook observability 
- **Tool blocking** — `ToolBlocked` event emitted when a hook blocks a tool, with hook name and reason
- **Hook audit trail** — `HookActed` events for every non-trivial hook action (message transforms, result transforms)
- **Core stays pure** — hooks return actions, runtime emits events, dispatcher handles both channels

### Future
- **OTel exporter** — a consumer that translates `SessionEvent` into OTel spans with `gen_ai.*` attributes
- **Live debugging** — attach a consumer mid-session to inspect agent behavior
- **Event buffering** — dispatcher can batch events before forwarding if needed
