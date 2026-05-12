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
| `InferenceStarted` | Provider call beginning, with model and message count | `runtime` before provider call |
| `InferenceCompleted` | Provider call succeeded, with full message, tokens, timing | `runtime` after successful response |
| `InferenceFailed` | Provider call failed, with error details and timing | `runtime` after error |
| `ToolStarted` | Tool execution beginning | `runtime` when executing tools |
| `ToolExecuted` | Tool execution finished, with result and timing | `runtime` after tool completion |
| `ToolBlocked` | Tool blocked by a hook | (reserved for hooks system) |
| `ExtensionActed` | Hook performed an action | (reserved for hooks system) |
| `SessionEnded` | Session concluded, with reason | (reserved, not yet emitted) |

All inference and tool events carry duration measurements (in monotonic milliseconds), and the inference events carry token counts when available from the provider. Session lifecycle events (SessionStarted, SessionEnded) and hook events (ExtensionActed) do not carry duration or tokens.

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
| `InferenceStarted` | `[:pig, :inference, :start]` | model, message_count |
| `InferenceCompleted` | `[:pig, :inference, :stop]` | model, duration, tokens (if present), finish_reason (if present) |
| `InferenceFailed` | `[:pig, :inference, :exception]` | model, error_type, duration, message_count |
| `ToolStarted` | `[:pig, :tool, :start]` | tool_name, tool_call_id, arguments_json |
| `ToolExecuted` | `[:pig, :tool, :stop]` | tool_name, tool_call_id, duration, result |
| `ToolBlocked` | `[:pig, :tool, :blocked]` | tool_name, tool_call_id, hook_name, reason |
| `SessionStarted` | *(not projected)* | — |
| `ExtensionActed` | *(not projected)* | — |
| `SessionEnded` | *(not projected)* | — |

**Heavy fields stay out of telemetry.** Full message content, tool results, and input message lists are pig-consumer territory. Telemetry gets lightweight identifiers and metrics only. This keeps `:telemetry` events cheap enough to fire on every agent step without impacting throughput.

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
2. **Dynamic** — any process can send `RegisterConsumer` to the dispatcher at runtime. This is useful for mid-session debugging. Dynamically attached consumers are not supervised.

### Dead consumer handling

When a consumer's actor crashes, its `Subject` becomes invalid. `process.send` to a dead subject is a no-op on the BEAM — the message lands in a dead mailbox and gets garbage collected. The dispatcher doesn't crash and doesn't need to explicitly detect dead consumers. If pruning becomes necessary later, a periodic sweep using `process.is_alive` can be added.

### Consumer specs

`pig/obs/consumer_spec.gleam` defines `ConsumerSpec` — a deferred recipe for starting a consumer. It bundles three things:

- `spec`: a `ChildSpecification(Nil)` for starting in a supervision tree
- `name`: a `Name(SessionEvent)` for recovering the subject after supervisor start
- `start_fn`: a `fn() -> Result(Subject(SessionEvent), StartError)` for the unsupervised start path

Builder functions like `pig.with_session_writer(path)` accumulate `ConsumerSpec` values on the config. No actors are spawned at config-construction time — the builder is pure data.

---

## 6. Dispatcher Actor

The dispatcher (`pig/obs/dispatcher.gleam`) is a standard Gleam OTP actor. Its internal state is a list of consumer subjects. It handles three messages:

- **`Event(SessionEvent)`** — emits telemetry, then fans out to all consumers. Always continues.
- **`RegisterConsumer(Subject)`** — adds the subject to the consumer list.
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

After `static_supervisor.start` returns, consumer subjects are recovered by name and registered with the dispatcher via `RegisterConsumer` messages. The agent is guaranteed to be idle at this point — it only processes events inside `Run` messages, which are sent later via `supervisor.run()`.

**Error handling:** supervisor start failures are returned as `Error(StartError)`.

### Standalone (`pig.gleam`)

`pig.start(config)` starts the dispatcher and consumers individually, without a supervisor. The dispatcher subject is wired directly into `RuntimeConfig` as a `Subject`. Each consumer's `start_fn` is called, and on success, the returned subject is registered with the dispatcher.

**Error handling:** if the dispatcher fails to start, or if any consumer fails to start, the function returns `Error(StartError)` rather than crashing. Previously started consumers are left running (no rollback) — this is acceptable for the standalone path since there's no supervision tree to clean up.

---

## 8. Design Decisions

### Why the runtime produces events, not the core

The pure core returns `StepResult` — a data value. It doesn't know how long a provider call took, whether a tool succeeded, or what the provider returned. Only the runtime, which actually performs IO, has this information. Putting event emission in the runtime keeps the core's dependency surface at zero and its test surface at `(state, msg) → StepResult`.

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
