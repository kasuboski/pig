# Hooks, Extensions, and Sessions Design

pig has three customization mechanisms, each with a distinct role:

- **Hooks** — lifecycle callbacks that mediate the agent loop (block tools, transform results, observe events)
- **Extensions** — functions that compose hooks, tools, skills, and state into reusable config modifiers
- **Sessions** — multi-turn conversations with persistence, replay, and lifecycle

---

## 1. Design Decisions

### D1: Rename `Extension` → `Hooks` ✓

The type originally called `Extension` in `src/pig/extension.gleam` was a bag of lifecycle callbacks. It didn't extend the agent — it mediated it. The name "extension" implies adding new capability. These callbacks intercept, transform, and observe what already exists.

**Decision:** Renamed to `Hooks`. The module is `hooks.gleam`. Builder functions are `hooks.new`, `hooks.on_tool_call`, etc. **Done.**

### D2: Drop `ExtensionStack` ✓

`ExtensionStack` wrapped `List(Extension)`. It added no behavior that a bare list couldn't provide. The composition functions now take `List(Hooks)` directly.

**Decision:** `ExtensionStack` removed. Composition functions take `List(Hooks)` as their first argument. **Done.**

### D3: Extensions are plain functions (`fn(PigConfig) -> PigConfig`)

pi needs a rich `ExtensionAPI` object because JavaScript extensions are dynamically loaded from the filesystem — the API object is their only interface to the agent. Gleam is compiled. Application code IS the wiring layer. There's no discovery, no runtime loading, no sandboxing boundary.

An extension is just a function that takes a `PigConfig` and returns a `PigConfig`. It can add tools, attach hooks, register skills, close over OTP actors for state — anything the builder API supports. No pig type needed.

**Decision:** No `Extension` type in pig. Extensions are `fn(PigConfig) -> PigConfig`.

### D4: Tools stay on `pig.with_tool()`

Tools are the agent's capability surface — they appear in tool definitions sent to the LLM, in the system prompt, in the `ToolRegistry`. They are not middleware. Moving tool registration into hooks or extensions would hide this first-class relationship.

**Decision:** Tools are registered via `pig.with_tool()`. Hooks can block or transform tool calls, but they don't define tools.

### D5: Agent actor IS the session ✓

A session is not a separate concept. The agent actor holds `AgentState` (config + history + iterations). Each `pig.run()` call adds to the history. The actor's lifecycle IS the session lifecycle.

**Decision:** The runtime actor holds `AgentState` instead of `AgentConfig`. History accumulates across `run()` calls. No `SessionManager` type, no separate session process. **Done.**

### D6: Session persistence via existing session writer

The session writer already records every `SessionEvent` to JSONL — every message, tool call, result, and inference. This IS the session log. The gap is replay: reading it back to reconstruct `List(Message)`.

**Decision:** Add `session.replay(path) -> Result(List(Message), ReplayError)`. The runtime calls this on init if `session_path` is set. Same JSONL file serves as both recording (via session writer consumer) and replay source.

### D7: Drop `persistence_path` from `PigConfig` ✓

The unused `persistence_path` was a premature placeholder. The session writer's path now doubles as the replay source, set via `with_session_writer()`.

**Decision:** `persistence_path` removed from `PigConfig`. **Done.**

### D8: Session lifecycle hooks ✓

Hooks that fire when a session starts and ends. Needed by extensions that manage state (e.g., initialize a store on start, close it on shutdown).

**Decision:** `on_session_start` and `on_session_shutdown` added to the `Hooks` type. **Done.**

---

## 2. What pi Does (Reference)

pi (TypeScript) has a full extension system at `packages/coding-agent/src/core/extensions/`. Key files:

- **`types.ts`** — ~1500 lines. `ExtensionEvent` union (~30 variants), `ExtensionAPI` interface, `ExtensionContext`, tool/command/shortcut/flag/provider registration.
- **`runner.ts`** — `ExtensionRunner` class. Iterates extensions, chains results per event type.
- **`loader.ts`** — Discovers extensions from filesystem, loads via jiti.
- **`wrapper.ts`** — Wraps extension-registered tools into `AgentTool`.

**Why pi has one big API surface:** JavaScript extensions are dynamically loaded packages. The `ExtensionAPI` object is their only interface to the agent. Everything — tools, events, commands, providers — goes through one object because there's no other way in.

**Why pig doesn't need this:** Gleam is compiled. Application code can call `pig.with_tool()`, `pig.with_hooks()`, and `pig.with_skill()` directly. There's no loading boundary to bridge.

**What transfers from pi:**
- Handlers return typed result objects that control flow
- Runner iterates all extensions with per-event composition semantics
- Rich context objects passed to handlers

**What doesn't transfer:**
- String-based event discrimination (`pi.on("tool_call", handler)`) — Gleam has typed variants
- Mutable event objects — Gleam is immutable
- Heterogeneous handler maps — loses type info
- Dynamic module loading — BEAM doesn't work that way

---

## 3. Current Implementation Status ✓

All core types, composition functions, and decision types are implemented in `src/pig/hooks.gleam`.

### Event types — one typed record per lifecycle hook:
```gleam
BeforeInferenceEvent(model, messages)
AfterInferenceEvent(model, message, duration_ms)
ToolCallEvent(tool_name, tool_call_id, arguments_json)
ToolResultEvent(tool_name, tool_call_id, result, is_error, duration_ms)
ErrorEvent(model, error)
CompleteEvent(model, message, total_iterations)
SessionStartEvent(history)
SessionShutdownEvent(history, iterations)
```

### Action types — what a handler returns:
```gleam
BeforeInferenceAction = KeepMessages | ReplaceMessages(messages)
ToolCallAction = AllowTool | BlockTool(reason)
ToolResultAction = KeepResult | ReplaceResult(content, is_error)
```

### Hooks type:
```gleam
Hooks(
  name: String,
  on_session_start, on_session_shutdown,
  on_before_inference, on_after_inference,
  on_tool_call, on_tool_result,
  on_error, on_complete,
)
```

### Decision types — carry attribution for observability:
```gleam
ToolCallDecision = ToolAllowed | ToolBlocked(hook_name, reason)
ToolResultDecision = ResultUnchanged(original_event) | ResultTransformed(final_event, transformers)
MessagesDecision = MessagesUnchanged(original) | MessagesReplaced(final_messages, transformers)
```

### Composition functions:
- `decide_tool_call(hooks_list, event) -> ToolCallDecision` — first Block wins
- `decide_tool_result(hooks_list, event) -> ToolResultDecision` — chain transformations
- `decide_messages(hooks_list, event) -> MessagesDecision` — chain replacements
- `notify_after_inference(hooks_list, event) -> Nil` — fire-and-forget
- `notify_error(hooks_list, event) -> Nil` — fire-and-forget
- `notify_complete(hooks_list, event) -> Nil` — fire-and-forget
- `notify_session_start(hooks_list, event) -> Nil` — fire-and-forget
- `notify_session_shutdown(hooks_list, event) -> Nil` — fire-and-forget

**Tests**: All passing in `test/pig/hooks_test.gleam`.

---

## 4. Architecture

### Where hooks run in the sans-IO architecture

Hooks are a **runtime concern**. The pure core (`update.gleam`) has no knowledge of hooks — it never imports `hooks.gleam`. The runtime interpreter (`runtime.gleam`) applies hooks as middleware on effects:

```text
Pure Core (update.gleam)
  │ returns StepResult with Effect values
  ▼
Runtime Interpreter (runtime.gleam)
  │
  │ For CallProvider effect:
  ├── hooks.decide_messages(hooks, BeforeInferenceEvent)  // may transform messages
  ├── call provider
  ├── hooks.notify_after_inference(hooks, AfterInferenceEvent)
  ├── emit SessionEvent(InferenceStarted / InferenceCompleted)
  │
  │ For ExecuteTools effect:
  ├── hooks.decide_tool_call(hooks, ToolCallEvent)         // may block
  ├── execute allowed tools (parallel)
  ├── hooks.decide_tool_result(hooks, ToolResultEvent)     // may transform result
  ├── emit SessionEvent(ToolStarted / ToolExecuted / ToolBlocked)
  │
  │ On loop completion:
  ├── hooks.notify_complete(hooks, CompleteEvent)
  ├── emit SessionEvent(SessionEnded)
```

### The three customization points

```text
pig.new(provider)                         // create config
  |> pig.with_tool(search_tool)           // add a capability
  |> pig.with_hooks(guard)                // add lifecycle mediation
  |> pig.with_skill(knowledge)            // add a knowledge domain
  |> pig.with_session_writer("sess.jsonl")// add persistence
  |> pig.start()                          // spawn agent (session)
```

| Mechanism | API point | What it does |
|---|---|---|
| **Tool** | `pig.with_tool()` | Adds an LLM-callable capability. Appears in tool definitions and system prompt. |
| **Hooks** | `pig.with_hooks()` | Lifecycle callbacks that mediate the agent loop. Block, transform, or observe. |
| **Skill** | `pig.with_skill()` | Knowledge domain with librarian tool. Adds context to the system prompt. |
| **Extension** | `fn(PigConfig) -> PigConfig` | Composes any combination of the above. No pig type. Just a function. |

### How hooks are stored and wired

1. `PigConfig` holds `hooks: List(Hooks)` — accumulated via `pig.with_hooks()`.
2. On `pig.start()` or `supervisor.start_supervised()`, hooks are passed into `RuntimeConfig`.
3. The runtime actor holds `RuntimeConfig` and calls hooks composition functions as middleware on effects.
4. The pure core (`update.gleam`) never sees hooks — it only sees `AgentMsg` values and returns `StepResult` values.

### How extensions compose

```gleam
// A safety extension: just hooks
pub fn with_safety_guard(config: pig.PigConfig) -> pig.PigConfig {
  config
  |> pig.with_hooks(
    hooks.new("safety-guard")
    |> hooks.on_tool_call(fn(event) {
      case event.tool_name {
        "bash" -> hooks.block_tool("Dangerous command")
        _ -> hooks.allow_tool()
      }
    })
  )
}

// A full extension: tools + hooks + state
pub fn with_gleam_deps(config: pig.PigConfig) -> pig.PigConfig {
  let assert Ok(store) = qmd_store.start()
  config
  |> pig.with_tool(make_search_tool(store))
  |> pig.with_hooks(
    hooks.new("gleam-deps")
    |> hooks.on_session_start(fn(_) { qmd_store.index(store) })
    |> hooks.on_session_shutdown(fn(_) { qmd_store.close(store) })
  )
}

// Application code: compose extensions
let agent =
  pig.new(provider)
  |> with_gleam_deps()
  |> with_safety_guard()
  |> pig.with_session_writer("sessions/01.jsonl")
  |> pig.start()
```

### Observability principle: runtime emits, hooks don't

Hook authors never touch telemetry. They return a typed action. The runtime emits the right `SessionEvent` to the dispatcher based on what actually happened.

| Hook returns | Runtime emits |
|---|---|
| `BlockTool(reason)` | `ToolBlocked` + `ExtensionActed` → dispatcher projects `[:pig, :tool, :blocked]` |
| `ReplaceResult(content)` | `ToolExecuted` (with transformed result) + `ExtensionActed` |
| `ReplaceMessages(msgs)` | `InferenceStarted` (with modified messages) + `ExtensionActed` |
| Fire-and-forget (observe) | Nothing extra — invisible by design |

---

## 5. Hooks Type

```gleam
// src/pig/hooks.gleam

/// A named set of lifecycle callbacks for mediating the agent loop.
/// Construct with `new(name)` and add handlers with `on_*` builder functions.
pub type Hooks {
  Hooks(
    name: String,
    on_session_start: fn(SessionStartEvent) -> Nil,
    on_session_shutdown: fn(SessionShutdownEvent) -> Nil,
    on_before_inference: fn(BeforeInferenceEvent) -> BeforeInferenceAction,
    on_after_inference: fn(AfterInferenceEvent) -> Nil,
    on_tool_call: fn(ToolCallEvent) -> ToolCallAction,
    on_tool_result: fn(ToolResultEvent) -> ToolResultAction,
    on_error: fn(ErrorEvent) -> Nil,
    on_complete: fn(CompleteEvent) -> Nil,
  )
}
```

### Hook categories

| Hook | Category | Returns | Composition |
|---|---|---|---|
| `on_session_start` | Fire-and-forget | `Nil` | All run, no short-circuit |
| `on_session_shutdown` | Fire-and-forget | `Nil` | All run, no short-circuit |
| `on_before_inference` | Transform | `BeforeInferenceAction` | Chain: each sees previous replacement |
| `on_after_inference` | Fire-and-forget | `Nil` | All run, no short-circuit |
| `on_tool_call` | Decision | `ToolCallAction` | First `BlockTool` wins |
| `on_tool_result` | Transform | `ToolResultAction` | Chain: each sees previous replacement |
| `on_error` | Fire-and-forget | `Nil` | All run, no short-circuit |
| `on_complete` | Fire-and-forget | `Nil` | All run, no short-circuit |

### Decision types

Composition functions return decision types that carry attribution:

```gleam
pub type ToolCallDecision {
  ToolAllowed
  ToolBlocked(hook_name: String, reason: String)
}

pub type ToolResultDecision {
  ResultUnchanged(original_event: ToolResultEvent)
  ResultTransformed(final_event: ToolResultEvent, transformers: List(String))
}

pub type MessagesDecision {
  MessagesUnchanged(original: List(Message))
  MessagesReplaced(final_messages: List(Message), transformers: List(String))
}
```

The runtime pattern-matches on the decision — `ToolBlocked` physically cannot coexist with a tool execution result.

---

## 6. Usage Examples

### Safety guard — hooks only

```gleam
pub fn with_safety_guard(config: pig.PigConfig) -> pig.PigConfig {
  config
  |> pig.with_hooks(
    hooks.new("safety-guard")
    |> hooks.on_tool_call(fn(event) {
      case event.tool_name {
        "bash" ->
          case string.contains(event.arguments_json, "rm -rf") {
            True -> hooks.block_tool("Dangerous command blocked")
            False -> hooks.allow_tool()
          }
        _ -> hooks.allow_tool()
      }
    })
  )
}
```

**What gets emitted automatically (hook author does nothing):**
- SessionEvent: `ToolBlocked(tool_call:, hook_name: "safety-guard", reason: "Dangerous command blocked")`
- Telemetry: `[:pig, :tool, :blocked]` with `hook_name: "safety-guard"`
- LLM sees: `Tool(tool_call_id: "c1", content: "Tool blocked by 'safety-guard': Dangerous command blocked")`

### Audit logger — fire-and-forget observer

```gleam
pub fn with_audit_log(config: pig.PigConfig) -> pig.PigConfig {
  config
  |> pig.with_hooks(
    hooks.new("audit-log")
    |> hooks.on_after_inference(fn(event) {
      io.println(
        "[audit] model=" <> event.model
        <> " duration=" <> int.to_string(event.duration_ms) <> "ms"
      )
    })
  )
}
```

**What gets emitted:** Nothing extra. Observers are invisible by design.

### PII scrubber — result transform

```gleam
pub fn with_pii_scrubber(config: pig.PigConfig) -> pig.PigConfig {
  config
  |> pig.with_hooks(
    hooks.new("pii-scrubber")
    |> hooks.on_tool_result(fn(event) {
      case event.is_error {
        True -> hooks.keep_result()
        False -> hooks.replace_result(content: scrub_pii(event.result), is_error: False)
      }
    })
  )
}
```

### Context injector — message transform

```gleam
pub fn with_context_enricher(config: pig.PigConfig) -> pig.PigConfig {
  config
  |> pig.with_hooks(
    hooks.new("context-enricher")
    |> hooks.on_before_inference(fn(event) {
      hooks.replace_messages([
        message.System("Current time: " <> get_current_time()),
        ..event.messages,
      ])
    })
  )
}
```

### Gleam deps — full extension (tool + hooks + state)

```gleam
// In a separate Gleam package: pig_gleam_deps

import pig
import pig/hooks.{type Hooks}
import pig/tool
import pig/ai/tool_definition

/// Extension that provides searchable Gleam dependency source code.
/// Adds a `search_gleam_deps` tool and manages a QMD index.
pub fn with_gleam_deps(config: pig.PigConfig) -> pig.PigConfig {
  let assert Ok(store) = qmd_store.start()

  let search_tool = tool.Tool(
    definition: tool_definition.ToolDefinition(
      name: "search_gleam_deps",
      description: "Search Gleam dependency packages for functions, types, and patterns",
      parameters: schema.object([
        #("query", schema.string()),
        #("package", schema.optional(schema.string())),
      ]),
    ),
    handler: fn(args) {
      let query = decode_query(args)
      let results = qmd_store.search(store, query)
      Ok(json.string(format_results(results)))
    },
  )

  config
  |> pig.with_tool(search_tool)
  |> pig.with_hooks(
    hooks.new("gleam-deps")
    |> hooks.on_session_start(fn(_) {
      qmd_store.index(store)
      io.println("[gleam_deps] store ready")
    })
    |> hooks.on_session_shutdown(fn(_) {
      qmd_store.close(store)
      io.println("[gleam_deps] store closed")
    })
  )
}
```

---

## 7. Session Persistence Design

### The problem

Each `pig.run()` call needs to accumulate history. The agent must remember between calls.

### The solution

The runtime actor holds `AgentState` instead of `AgentConfig`:

```gleam
// state.gleam
pub type AgentState {
  AgentState(
    config: AgentConfig,
    history: List(Message),
    iterations: Int,
  )
}
```

On init, if `session_path` is set, replay from JSONL:

```gleam
fn init(config: AgentConfig) -> AgentState {
  let history = case config.session_path {
    Some(path) -> {
      let assert Ok(msgs) = session.replay(path)
      msgs
    }
    None -> []
  }
  let state = AgentState(config:, history:, iterations: 0)
  hooks.notify_session_start(config.hooks, SessionStartEvent(history:))
  state
}
```

### Session replay

```gleam
// pig/obs/session.gleam — planned addition
pub fn replay(path: String) -> Result(List(Message), ReplayError) {
  case simplifile.read(path) {
    Error(e) -> Error(FileError(string.inspect(e)))
    Ok(content) -> {
      let lines =
        content
        |> string.split("\n")
        |> list.filter(fn(l) { l != "" })
      case lines {
        [] -> Ok([])
        _ -> replay_lines(lines)
      }
    }
  }
}
```

### Why no separate session concept

| Session need | How pig handles it |
|---|---|
| Multi-turn history | Runtime actor holds `AgentState`, history accumulates |
| Persistence | Session writer already writes JSONL |
| Crash recovery | `session.replay()` on actor init |
| Session listing | Application-level — keep a `Dict(String, Agent)` |
| Branching | Not needed yet — single linear history |
| Compaction | Not needed yet — can be added as a hook |

---

## 8. Testing Strategy

Per `TESTING_STRATEGY.md`:

- **Pure functions:** All hook logic is `fn(Event) -> Action`. Test with value-in, value-out.
- **Composition:** Test `decide_tool_call`, `decide_tool_result`, `decide_messages` directly with `List(Hooks)` — no OTP processes needed.
- **Decision types are testable:** Pattern match on `ToolBlocked(hook_name:, reason:)` to assert both values.
- **Runtime integration:** Hooks are wired through the runtime. Test with the test harness that provides a stub provider.
- **No mocks needed:** Hooks are functions. Create test hooks inline.
- **Telemetry assertions:** Use `capture_scenario` harness with test listener.

```gleam
// Example: decision carries attribution
pub fn decision_carries_attribution_test() {
  let guard =
    hooks.new("guard")
    |> hooks.on_tool_call(fn(_) { hooks.block_tool("nope") })
  let event = ToolCallEvent(tool_name: "bash", tool_call_id: "1", arguments_json: "{}")
  let decision = hooks.decide_tool_call([guard], event)
  decision == ToolBlocked(hook_name: "guard", reason: "nope")
}

// Example: extension is just a function
pub fn extension_composes_tools_and_hooks_test() {
  let config =
    pig.test_harness()
    |> with_safety_guard()
  let hooks_list = pig.agent_config(config).hooks
  list.length(hooks_list) |> should.equal(1)
}
```

---

## 9. What We're NOT Building

Deferred until there's a real need:

- **Tool registration from hooks** — pig already has `pig.with_tool()`. Extensions compose tools externally.
- **Command/shortcut system** — pig has no command system yet.
- **Filesystem extension discovery** — Gleam is compiled. Extensions are functions in code.
- **Provider registration from hooks** — can't swap the provider mid-loop.
- **Branching/compaction** — single linear history for now. Can be added as hooks later.
- **Session switching** — application-level concern. Keep a `Dict(String, Agent)`.

---

## 10. Resolved Design Questions

### Blocked tool → what message does the LLM see? — RESOLVED (Option A)

**Decision: Option A — Error Tool message with the hook's reason.**

When a hook blocks a tool call, the LLM needs a `Tool` message in the conversation history so it can adapt its behavior. The message includes the hook name and the reason the hook provided:

```gleam
// Hook returns:
hooks.block_tool("Removing files recursively is not allowed")

// LLM sees:
Tool(
  tool_call_id: "c1",
  content: "Tool blocked by 'safety-guard': Removing files recursively is not allowed",
)
```

The hook author controls what the LLM sees through the reason string. A good reason helps the LLM self-correct: `"Use 'trash' instead of 'rm' for file deletion"` is more useful than `"blocked"`.

### Hook purity and state

Hooks are pure functions. But what if a hook needs to track state across turns (e.g., "count of blocked tools")?

**Decision: Option A.** If you need state, wrap it in an OTP actor outside the hooks and close over the subject in your handler. The hooks system doesn't manage state. This is simpler and composes without type gymnastics. The extension function (`fn(PigConfig) -> PigConfig`) is the natural place to start actors and close over them.
