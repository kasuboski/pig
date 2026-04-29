# Observability Architecture

pig uses a **dispatcher-actor pattern** for all observability. The agent core emits typed `SessionEvent` values to a single dispatcher actor. The dispatcher always projects lightweight telemetry to the BEAM `:telemetry` library, then fans out the full event to registered consumers.

---

## 1. Design Goals

- **Single emission point from core** — `core.gleam` sends one message per event. No telemetry calls, no consumer iteration.
- **Telemetry always-on by construction** — built into the dispatcher handler, not a registration convention.
- **Structured data for pig consumers** — full typed `SessionEvent` variants for session writer, terminal, OTel.
- **Lightweight projection for BEAM ecosystem** — flat metrics via `:telemetry` for LiveDashboard, AppSignal, etc.
- **Dynamic consumer registration** — consumers can attach and detach at runtime.
- **Independent consumer lifecycles** — a crashed consumer doesn't affect the dispatcher or other consumers.

---

## 2. Architecture

```
pig/agent/core.gleam
  │
  └── process.send(dispatcher, SessionEvent)       // ONE send per event

pig/obs/dispatcher.gleam (EventDispatcher actor)
  │
  ├── emit_telemetry(event)                        // ALWAYS: lightweight projection
  │     └── telemetry.execute(["pig", ...], ...)   //   to BEAM ecosystem
  │
  └── fan-out to registered consumers:             // fire-and-forget sends
        ├── session writer     → JSONL file
        ├── terminal printer   → stdout
        └── future OTel        → OpenTelemetry spans
```

### What core.gleam looks like

```gleam
// Before: core calls telemetry directly
events.emit(events.InferenceStart(model:, message_count: msg_count))
// ... do work ...
events.emit(events.InferenceStop(model:, message_count:, duration_ms:, ...))

// After: core sends SessionEvent to dispatcher via same events module
// (events.emit becomes a thin wrapper around process.send)
events.emit(st.config.dispatcher, events.InferenceStarted(model:, message_count: msg_count))
// ... do work ...
events.emit(st.config.dispatcher, events.InferenceCompleted(message:, duration_ms:, ...))
```

Core never calls `telemetry.execute`. Core never imports the dispatcher module. Core never iterates consumers. The `events` module stays the API surface — `events.emit` wraps `process.send` to the dispatcher. Core only needs to pass state (which carries the dispatcher subject). See §2a for the wrapper design.

### §2a — `events.emit` wrapper

The current `events.emit(event: Event)` calls `:telemetry.execute` directly. The new version takes only what it needs — the dispatcher subject and the event:

```gleam
// In pig/obs/events.gleam

/// Send a SessionEvent to the dispatcher.
/// Takes the dispatcher subject directly — only what it needs.
pub fn emit(
  dispatcher: Subject(dispatcher.Message),
  event: SessionEvent,
) -> Nil {
  process.send(dispatcher, dispatcher.Event(event))
}

/// Get the current monotonic time for duration measurement.
pub fn system_time() -> Int {
  ffi_system_time()
}
```

This keeps the same level of indirection core has today. The change at each call site is mechanical — add `st.config.dispatcher,` as the first argument and swap `Event` constructors for `SessionEvent` constructors. Core still only imports `pig/obs/events`.

**Why `Subject` and not `AgentState`:** `emit` sends a message. It needs a destination and a payload. Taking the full state would hide what it actually does and create unnecessary coupling to `AgentConfig`'s shape. Both `core.gleam` and `parallel.gleam` have `st` in scope and access the dispatcher via `st.config.dispatcher` — no ergonomics lost.

### What the dispatcher does

```gleam
fn handle_message(state, msg) {
  case msg {
    Event(event) -> {
      emit_telemetry(event)                      // always
      list.each(state.consumers, fn(consumer) {  // fan-out
        process.send(consumer, event)
      })
      actor.continue(state)
    }
    RegisterConsumer(subject) -> {
      actor.continue(State(consumers: [subject, ..state.consumers]))
    }
  }
}
```

---

## 3. SessionEvent Type

The single source of truth. Typed variants for every lifecycle event. Carries full structured data.

```gleam
pub type SessionEvent {
  // Session lifecycle
  SessionStarted(
    agent_id: Option(String),
    agent_name: Option(String),
    model: String,
    provider_name: Option(String),
    system_prompt: Option(String),
  )

  // Inference — "started" variant added for telemetry pairing
  InferenceStarted(
    model: String,
    message_count: Int,
  )
  InferenceCompleted(
    message: Message,
    response_id: Option(String),
    response_model: Option(String),
    finish_reason: Option(String),
    input_tokens: Option(Int),
    output_tokens: Option(Int),
    duration_ms: Int,
    input_messages: List(Message),
  )

  // Tool execution — "started" variant added for telemetry pairing
  ToolStarted(
    tool_call: ToolCall,
  )
  ToolExecuted(
    tool_call: ToolCall,
    result: String,
    duration_ms: Int,
  )

  // Tool blocked by extension (new)
  ToolBlocked(
    tool_call: ToolCall,
    extension_name: String,
    reason: String,
  )

  // Extension action (new — for full audit trail)
  ExtensionActed(
    extension_name: String,
    hook: ExtensionHook,
    action: ExtensionActionDetail,
  )

  // Errors and completion
  InferenceFailed(
    error: AiError,
    duration_ms: Int,
    input_messages: List(Message),
  )
  SessionEnded(reason: SessionEndReason)
}
```

**Changes from current code:**
- `InferenceStarted` — new (enables telemetry `[:pig, :inference, :start]`)
- `ToolStarted` — new (enables telemetry `[:pig, :tool, :start]`)
- `ToolBlocked` — new (tool blocked by extension, not executed)
- `ExtensionActed` — new (extension audit trail)

### Why "started" variants?

BEAM telemetry conventions use start/stop pairs for duration tracking. Tools like `Telemetry.Metrics` and `opentelemetry_telemetry` expect `[:pig, :inference, :start]` before `[:pig, :inference, :stop]`. Without the "started" events, the dispatcher can't emit the start-half of these pairs. Session consumers also benefit — the session writer can log "calling provider..." before the result arrives.

---

## 4. Telemetry Projection

The dispatcher's `emit_telemetry` function pattern-matches on `SessionEvent` and projects lightweight fields to `:telemetry`. This is a pure function inside the dispatcher.

```gleam
fn emit_telemetry(event: SessionEvent) -> Nil {
  case event {
    InferenceStarted(model:, message_count:) ->
      ffi_execute(
        ["pig", "inference", "start"],
        dict.from_list([#("system_time", ffi_system_time()), #("message_count", message_count)]),
        dict.from_list([#("model", model)]),
      )

    InferenceCompleted(duration_ms:, input_tokens:, output_tokens:, ...) ->
      ffi_execute(
        ["pig", "inference", "stop"],
        dict.from_list([#("system_time", ffi_system_time()), #("duration", duration_ms), ...]),
        dict.from_list([#("model", ...)]),
      )

    ToolStarted(tool_call:) ->
      ffi_execute(
        ["pig", "tool", "start"],
        dict.from_list([#("system_time", ffi_system_time())]),
        dict.from_list([#("tool_name", tool_call.name), #("tool_call_id", tool_call.id)]),
      )

    ToolExecuted(duration_ms:, ...) ->
      ffi_execute(
        ["pig", "tool", "stop"],
        dict.from_list([#("system_time", ffi_system_time()), #("duration", duration_ms)]),
        dict.from_list([#("tool_name", ...), #("tool_call_id", ...)]),
      )

    ToolBlocked(tool_call:, extension_name:) ->
      ffi_execute(
        ["pig", "tool", "blocked"],
        dict.from_list([#("system_time", ffi_system_time())]),
        dict.from_list([#("tool_name", tool_call.name), #("extension_name", extension_name)]),
      )

    // Events not projected to telemetry: SessionStarted, ExtensionActed,
    // InferenceFailed, SessionEnded — these are pig-specific.
    // Could be projected later if BEAM consumers want them.
    _ -> Nil
  }
}
```

### What telemetry does NOT carry

| Field | In SessionEvent | In telemetry | Why |
|-------|----------------|-------------|-----|
| `result` (tool output) | ✅ Full string | ❌ | Too heavy, belongs in session/OTel |
| `arguments_json` | ✅ Full JSON | ❌ | Too heavy, potentially sensitive |
| `input_messages` | ✅ Full list | ❌ | Structured data doesn't fit flat dict |
| `message` (assistant) | ✅ Full record | ❌ | Structured, needs typed consumer |
| `duration_ms` | ✅ | ✅ | Standard metric |
| `model` | ✅ | ✅ | Standard metric |
| `tool_name`, `tool_call_id` | ✅ | ✅ | Lightweight identifiers |
| `input_tokens`, `output_tokens` | ✅ | ✅ | Standard metrics |

### Telemetry event names (preserved from current code)

| Event | Name |
|-------|------|
| InferenceStarted | `[:pig, :inference, :start]` |
| InferenceCompleted | `[:pig, :inference, :stop]` |
| InferenceFailed | `[:pig, :inference, :exception]` |
| ToolStarted | `[:pig, :tool, :start]` |
| ToolExecuted | `[:pig, :tool, :stop]` |
| ToolBlocked | `[:pig, :tool, :blocked]` (new) |

---

## 5. Consumer Registration

### Builder API

```gleam
let config =
  pig.new(provider)
  |> pig.with_model("gpt-4o")
  |> pig.with_session_writer("./sessions/run.jsonl")  // accumulates ChildSpec
  |> pig.with_terminal_output()                        // accumulates ChildSpec
```

### How registration works

Each `with_*` builder function accumulates a `ChildSpecification(Nil)` (a start recipe) on the config. **No actors are spawned at config time.** The builder is pure data.

Every consumer module exposes a `supervised()` function — the same pattern used by `agent/actor.gleam`:

```gleam
// In pig/obs/session.gleam
pub fn supervised(
  path: String,
  name: Name(SessionEvent),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let builder =
      actor.new(State(path:))
      |> actor.on_message(handle_message)
      |> actor.named(name)
    case actor.start(builder) {
      Ok(started) -> Ok(Started(data: Nil, pid: started.pid))
      Error(e) -> Error(e)
    }
  })
}
```

And the builder accumulates specs:

```gleam
// PigConfig stores start recipes, not running processes
pub opaque type PigConfig {
  PigConfig(
    agent_config: state.AgentConfig,
    skills: List(skill.Skill),
    persistence_path: Option(String),
    consumer_specs: List(ConsumerSpec),
  )
}

type ConsumerSpec {
  ConsumerSpec(
    spec: supervision.ChildSpecification(Nil),
    name: Name(SessionEvent),
  )
}

pub fn with_session_writer(config: PigConfig, path: String) -> PigConfig {
  let name = process.new_name("pig_session_writer")
  let spec = session.supervised(path, name)
  PigConfig(..config, consumer_specs: [
    ConsumerSpec(spec:, name:), ..config.consumer_specs
  ])
}
```

At `start()` time, the specs are folded into the static supervisor (see §7). After the supervisor starts, consumer subjects are recovered via `named_subject()` and registered with the dispatcher.

### Dynamic registration

Because the dispatcher accepts `RegisterConsumer` as a message, consumers can also attach at runtime (outside the supervision tree):

```gleam
// Mid-session: attach a debugger
let debugger = my_debugger.start()
process.send(dispatcher, RegisterConsumer(debugger))
```

Dynamically attached consumers are not supervised — they follow the "best-effort observability" model.

---

## 6. Dispatcher Actor Design

### Module: `pig/obs/dispatcher.gleam`

```gleam
type State {
  State(consumers: List(Subject(SessionEvent)))
}

type Message {
  Event(SessionEvent)
  RegisterConsumer(Subject(SessionEvent))
}
```

### Error handling for dead consumers

When a consumer's actor crashes, its `Subject` becomes invalid. `process.send` to a dead subject is a no-op on the BEAM — the message lands in a dead mailbox and gets garbage collected. The dispatcher doesn't crash. No explicit dead-consumer detection needed.

If we want to prune dead consumers from the list later, we can add a periodic sweep that tries `process.is_alive` on each subject. Not needed for v1.

---

## 7. Supervision Tree

### Current tree (before dispatcher)

```
Supervisor (OneForOne)
  └── pig_agent (actor)          ← agent/actor.gleam, holds AgentConfig
        └── runs core.gleam which calls events.emit() directly
```

The agent actor is the only supervised child. Session writer and terminal printer are not supervised — they don't exist yet in the running system.

### New tree (dispatcher + supervised consumers in event subtree)

```
AppSupervisor (OneForOne)                      ← pig/supervisor.gleam
  ├── EventSupervisor (OneForOne)               ← child static_supervisor
  │     ├── event_dispatcher                     ← pig/obs/dispatcher.gleam
  │     ├── session_writer                       ← pig/obs/session.gleam
  │     └── terminal_printer                     ← pig/obs/terminal.gleam
  └── pig_agent                                  ← pig/agent/actor.gleam
```

This is the standard OTP pattern: a top-level supervisor with child supervisors underneath. Each subtree is its own crash domain. The top-level `OneForOne` keeps the event tree and agent tree completely isolated — a crash in the event tree never touches the agent.

### Why a nested supervisor (not flat)

A flat `RestForOne` with dispatcher + consumers + agent as siblings means a consumer crash could cascade to the agent. That's wrong — observability should never destabilize the agent. The nested structure means:

- The event subtree manages its own restart domain. The dispatcher and consumers restart independently under `OneForOne`.
- The agent subtree is a separate child of the top-level supervisor. Agent crashes never affect the event tree.
- Startup order is guaranteed: `EventSupervisor` starts first (registered first), then `pig_agent`. The agent's `AgentConfig` carries the dispatcher subject, so it can send events from the start.
- Coordinated lifecycle: the top-level supervisor starts and stops everything together.

### Restart re-registration

With `OneForOne` inside the event subtree, a restarted consumer gets a new `Subject`. The dispatcher still holds the old (dead) subject. Options:

1. **v1: accept the gap.** Dead-subject sends are no-ops on the BEAM. The consumer restarts but doesn't receive events until re-registered. Best-effort observability.
2. **Future: consumer self-registers.** The ChildSpec's `start` function calls `process.named_subject(dispatcher_name)` and sends `RegisterConsumer`. Requires the dispatcher name to be a stable constant.
3. **Future: dispatcher prunes dead subjects.** Periodic sweep with `process.is_alive()`.

### How specs are composed

Each `with_*` builder accumulates a `ChildSpecification(Nil)` on the config. At start time, the specs are folded into the event subtree's supervisor builder. After the supervisor starts, consumer subjects are recovered and registered with the dispatcher.

```gleam
// In pig/supervisor.gleam

/// A deferred consumer: a ChildSpec + the name to recover its Subject after start.
pub type ConsumerSpec {
  ConsumerSpec(
    spec: supervision.ChildSpecification(Nil),
    name: Name(SessionEvent),
  )
}

pub fn start_supervised(
  agent_config: state.AgentConfig,
  consumer_specs: List(ConsumerSpec),
) -> Result(SupervisedAgent, otp_actor.StartError) {
  let dispatcher_name = process.new_name("pig_event_dispatcher")
  let agent_name = process.new_name("pig_agent")

  // Wire dispatcher name into agent config
  let agent_config = state.AgentConfig(
    ..agent_config,
    dispatcher_name: dispatcher_name,
  )

  // Build event subtree: dispatcher → consumers
  let event_tree =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(dispatcher.supervised(dispatcher_name))
    |> list.fold(consumer_specs, _, fn(builder, entry) {
      static_supervisor.add(builder, entry.spec)
    })

  // Build top-level: event subtree → agent
  let app_tree =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(event_tree |> static_supervisor.supervised)
    |> static_supervisor.add(actor.supervised(agent_config, agent_name))

  case static_supervisor.start(app_tree) {
    Ok(started) -> {
      let dispatcher_subject = process.named_subject(dispatcher_name)
      let agent_subject = process.named_subject(agent_name)

      // Register all consumers with the dispatcher
      list.each(consumer_specs, fn(entry) {
        let consumer_subject = process.named_subject(entry.name)
        process.send(
          dispatcher_subject,
          dispatcher.RegisterConsumer(consumer_subject),
        )
      })

      Ok(SupervisedAgent(subject: agent_subject, sup_pid: started.pid))
    }
    Error(e) -> Error(e)
  }
}
```

### Changes to `pig.gleam` (standalone / unsupervised start)

For users who don't call `start_supervised`, the standalone `start()` starts the dispatcher and agent without a supervisor. Consumer specs are started individually:

```gleam
pub fn start(config: PigConfig) -> Result(Agent, StartError) {
  let final_config = build_agent_config(config)
  // Start dispatcher
  let assert Ok(dispatcher_subject) = dispatcher.start()
  let final_config = state.AgentConfig(
    ..final_config,
    dispatcher: dispatcher_subject,
  )
  // Start and register each consumer (unsupervised)
  list.each(config.consumer_specs, fn(entry) {
    let assert Ok(_) = entry.spec.start()
    let consumer_subject = process.named_subject(entry.name)
    process.send(
      dispatcher_subject,
      dispatcher.RegisterConsumer(consumer_subject),
    )
  })
  case agent_actor.start(final_config) {
    Ok(subject) -> Ok(Agent(subject))
    Error(e) -> Error(e)
  }
}
```

---

## 8. Sequencing: Config-Time vs. Start-Time

### The problem

Builder functions like `with_session_writer` need to register consumers with the dispatcher. But the dispatcher doesn't exist at config-construction time — it's created in `start()`.

```
pig.new(provider)                              // no dispatcher yet
  |> pig.with_session_writer("./out.jsonl")    // wants to register consumer... with whom?
  |> pig.start()                               // dispatcher created here
```

### Solution: ChildSpec accumulation

Instead of spawning actors in the builder, accumulate `ChildSpecification(Nil)` values — pure data recipes for starting supervised processes. This is the same pattern `agent/actor.gleam` already uses.

**Builder functions create specs, not processes:**

```gleam
pub fn with_session_writer(config: PigConfig, path: String) -> PigConfig {
  let name = process.new_name("pig_session_writer")
  let spec = session.supervised(path, name)  // pure data, no spawn
  PigConfig(..config, consumer_specs: [
    ConsumerSpec(spec:, name:), ..config.consumer_specs
  ])
}
```

**`start()` / `start_supervised()` fold specs into the supervisor:**

- `start_supervised()` folds all specs into the static supervisor builder via `list.fold`. The supervisor starts dispatcher → consumers → agent in order. After startup, consumer subjects are recovered by name and registered with the dispatcher.
- `start()` calls each spec's `start` function individually, then registers.

**Why this works:**

- `ChildSpecification` is just a closure `fn() -> Result(Started(data), StartError)`. It captures its arguments (e.g., file path) but doesn't run until the supervisor calls it.
- No actors sit idle between config construction and start.
- The builder is pure — no side effects, no process spawning, safe to inspect and test.
- The pattern is identical to how `agent/actor.supervised()` already works.

---

## 9. Changes to Existing Code

### Files to modify

| File | Change |
|------|--------|
| `src/pig/obs/events.gleam` | Add `InferenceStarted`, `ToolStarted`, `ToolBlocked`, `ExtensionActed` to `SessionEvent`. Keep `Event` type for telemetry projection types used internally by the dispatcher. Change `emit` to take `Subject(dispatcher.Message)` + `SessionEvent` and wrap `process.send` (see §2a). |
| `src/pig/agent/state.gleam` | Add `dispatcher_name: Name(dispatcher.DispatcherMessage)` to `AgentConfig`. |
| `src/pig/agent/core.gleam` | Swap `events.emit(Event)` → `events.emit(st.config.dispatcher, SessionEvent)` at each call site. Same import, same module, mechanical change. |
| `src/pig/agent/parallel.gleam` | Same — swap `events.emit(Event)` → `events.emit(st.config.dispatcher, SessionEvent)`. |
| `src/pig.gleam` | Add `consumer_specs: List(ConsumerSpec)` to `PigConfig`. Add `with_session_writer`, `with_terminal_output`. Update `start()` to create dispatcher and start/register consumers from specs. |
| `src/pig/supervisor.gleam` | Add `ConsumerSpec` type. Accept consumer specs in `start_supervised()`. Build nested tree: event subtree (OneForOne) under top-level AppSupervisor (OneForOne). Post-start registration loop. |
| `src/pig/obs/session.gleam` | Add `supervised(path, name) -> ChildSpecification(Nil)` function. Refactor message type to accept `SessionEvent` directly (dispatcher sends `SessionEvent`, not `WriterMessage`). Handle new variants in `format_event`. |
| `src/pig/obs/terminal.gleam` | Add `supervised(name) -> ChildSpecification(Nil)` function. Already accepts `SessionEvent` directly. Handle new variants in `format_event`. |

### Files to create

| File | Purpose |
|------|---------|
| `src/pig/obs/dispatcher.gleam` | Dispatcher actor: built-in telemetry emission + consumer fan-out. |
| `test/pig/obs/dispatcher_test.gleam` | Tests for dispatcher: telemetry projection, consumer fan-out, dynamic registration. |

### Telemetry FFI stays

The `pig_obs_ffi` Erlang module and the `emit`/`system_time` FFI functions in `events.gleam` remain. The dispatcher calls them internally for its `emit_telemetry` function. The public `events.emit()` function is no longer called from core.gleam, but stays for backward compat and testing.

---

## 10. Implementation Order

1. **Add new `SessionEvent` variants** — `InferenceStarted`, `ToolStarted`, `ToolBlocked`, `ExtensionActed` to `obs/events.gleam`.
2. **Create `pig/obs/dispatcher.gleam`** — the actor with built-in telemetry + fan-out. Include `supervised(name) -> ChildSpecification(Nil)`. Write tests.
3. **Add `supervised()` to consumer modules** — `session.supervised(path, name)` and `terminal.supervised(name)`. Refactor session writer to accept `SessionEvent` directly.
4. **Add `dispatcher_name` field to `AgentConfig`** — `state.gleam`.
5. **Wire core.gleam and parallel.gleam** — swap `events.emit(Event)` → `events.emit(st.config.dispatcher, SessionEvent)` at each call site. Mechanical: add `st.config.dispatcher,` first arg, swap constructors.
6. **Update `pig.gleam`** — add `ConsumerSpec` type, `consumer_specs` field, `with_session_writer`, `with_terminal_output`. Update `start()` to start dispatcher, start/register consumers from specs.
7. **Update `pig/supervisor.gleam`** — accept `List(ConsumerSpec)`, build nested tree: event subtree (OneForOne) as child of top-level AppSupervisor (OneForOne), post-start registration loop.
8. **Integration tests** — verify telemetry still fires, supervised consumers receive events, dynamic registration works.
9. **Remove heavy fields from telemetry projection** — stop projecting `result`, `arguments_json` from the dispatcher's `emit_telemetry`.

---

## 11. What This Enables

### Immediate
- **Session replay** — full structured JSONL with before/after events
- **Terminal output** — real-time formatted display of agent activity
- **Test assertions** — tests can register a capture consumer and assert on event sequences

### Near-term (extensions)
- **Tool blocking** — `ToolBlocked` event emitted when extension blocks a tool
- **Extension audit trail** — `ExtensionActed` events for every non-trivial extension action
- **Core stays simple** — extensions return actions, core emits events, dispatcher handles both channels

### Future
- **OTel exporter** — a consumer that translates `SessionEvent` into OTel spans with `gen_ai.*` attributes
- **Live debugging** — attach a consumer mid-session to inspect agent behavior
- **Event buffering** — dispatcher can batch events before forwarding if needed
