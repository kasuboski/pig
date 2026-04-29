# Extension System Design

A system for hooking into the agent lifecycle — blocking tool calls, transforming results, reacting to events, and injecting context.

---

## 1. Goals

- **Library users** can customize agent behavior without forking pig
- **Type-safe** — every hook has typed input and output, no stringly-typed event names
- **Make invalid states unrepresentable** — the type system should prevent impossible combinations (e.g. a tool call can't be both "blocked" and "executed")
- **Pure** — extensions are functions, not processes. The core loop stays pure and testable
- **Composable** — multiple extensions combine predictably with clear precedence rules
- **Observable by default** — extension effects are automatically visible in both observability channels. Extension authors should NOT need to emit their own telemetry. The core loop emits the right events based on what actually happened.
- **Minimal** — small API surface, pay-for-what-you-use

---

## 2. What pi Does (Reference)

pi (TypeScript) has a full extension system at `packages/coding-agent/src/core/extensions/`. Key files:

- **`types.ts`** — ~1500 lines. Defines `ExtensionEvent` union type (~30 variants), `ExtensionAPI` interface, `ExtensionContext`, `ExtensionHandler`, typed result objects per event, tool definitions, commands, shortcuts, flags, provider registration.
- **`runner.ts`** — `ExtensionRunner` class. Iterates extensions, chains results per event type, catches errors, emits `ExtensionError` to listeners. Has specialized emit methods per event type (`emitToolCall`, `emitToolResult`, `emitContext`, `emitBeforeAgentStart`, `emitInput`).
- **`loader.ts`** — Discovers extensions from filesystem (`~/.pi/agent/extensions/`, `.pi/extensions/`), loads via jiti (TypeScript without compilation), creates `ExtensionAPI` per extension, manages shared `ExtensionRuntime`.
- **`wrapper.ts`** — Wraps extension-registered tools into the agent-core `AgentTool` interface.

**Key pi patterns that transfer:**
- Extension is a factory function receiving an API object
- Handlers return typed result objects that control flow
- ExtensionRunner iterates all extensions with per-event composition semantics
- Rich context object passed to handlers

**Key pi patterns that DON'T transfer to Gleam:**
- String-based event discrimination (`pi.on("tool_call", handler)`) — Gleam has no union types with runtime discrimination by string field
- Mutable event objects (`event.input.command = "..."`) — Gleam is immutable
- Heterogeneous handler maps (`Map<string, HandlerFn[]>`) — loses type info
- Async handlers — Gleam uses OTP processes, not async/await
- Dynamic module loading from filesystem — would require BEAM hot code loading

---

## 3. Current Implementation Status

### Done: Core types and stack composition (`src/pig/extension.gleam`)

**Event types** — one typed record per lifecycle hook:
```gleam
BeforeInferenceEvent(model, messages)
AfterInferenceEvent(model, message, duration_ms)
ToolCallEvent(tool_name, tool_call_id, arguments_json)
ToolResultEvent(tool_name, tool_call_id, result, is_error, duration_ms)
ErrorEvent(model, error)
CompleteEvent(model, message, total_iterations)
```

**Action types** — what a handler returns:
```gleam
BeforeInferenceAction = KeepMessages | ReplaceMessages(messages)
ToolCallAction = AllowTool | BlockTool(reason)
ToolResultAction = KeepResult | ReplaceResult(content, is_error)
```

**Extension type** — named bundle of handler functions:
```gleam
Extension(name, on_before_inference, on_after_inference, on_tool_call, on_tool_result, on_error, on_complete)
```

**ExtensionStack** — list of extensions with composition functions:
- `should_allow_tool_call(stack, event) -> Result(Nil, String)` — first Block wins
- `transform_tool_result(stack, event) -> ToolResultEvent` — chain transformations
- `transform_messages(stack, event) -> List(Message)` — chain replacements
- `notify_after_inference(stack, event) -> Nil` — fire-and-forget
- `notify_error(stack, event) -> Nil` — fire-and-forget
- `notify_complete(stack, event) -> Nil` — fire-and-forget

**Tests**: 33 passing in `test/pig/extension_test.gleam`. All 271 total tests green.

### Not Yet Done: Integration

The following steps remain:
- [ ] Refactor stack functions to return **decision types with attribution** (see §5)
- [ ] Add `extension_stack` field to `AgentConfig` in `agent/state.gleam`
- [ ] Wire extension calls into `agent/core.gleam` at each lifecycle point
- [ ] Wire extension calls into `agent/parallel.gleam` for parallel tool execution
- [ ] Add `with_extension` / `with_extensions` to `pig.gleam` public API
- [ ] Add `ExtensionActed` to `SessionEvent` in `obs/events.gleam`
- [ ] Update session writer (`obs/session.gleam`) and terminal printer (`obs/terminal.gleam`) to handle new event
- [ ] Write integration tests via harness

---

## 4. Observability Integration Design

pig has two observability channels (see `RESOLVED_DECISIONS.md` §10):

| Channel | Transport | Content | Consumers |
|---------|-----------|---------|-----------|
| `:telemetry` (Event) | `telemetry.execute/3` | Lightweight metrics | BEAM tools (LiveDashboard, OTel) |
| `SessionEvent` | Actor messages | Full content + metadata | Session writer, terminal printer, future OTel exporter |

**Current telemetry events** (emitted from `core.gleam` and `parallel.gleam`):
```
InferenceStart(model, message_count)
InferenceStop(model, message_count, duration_ms, response_id, finish_reason, input_tokens, output_tokens)
InferenceException(model, message_count, error_type)
ToolStart(tool_name, tool_call_id, arguments_json)
ToolStop(tool_name, tool_call_id, duration_ms, result)
ToolException(tool_name, tool_call_id, arguments_json)
```

**Current SessionEvents** (defined in `obs/events.gleam` but NOT YET emitted from core):
```
SessionStarted(agent_id, agent_name, model, provider_name, system_prompt)
InferenceCompleted(message, response_id, response_model, finish_reason, input_tokens, output_tokens, duration_ms, input_messages)
ToolExecuted(tool_call, result, duration_ms)
InferenceFailed(error, duration_ms, input_messages)
SessionEnded(reason)
```

### Design Principle: Core Emits, Extensions Don't

Extension authors should NOT need to think about telemetry. The contract is:

> You return a typed action from your handler. The core loop uses that action to decide what to do, and emits the right events to both channels with full attribution.

This means:
- An extension that blocks a tool → core emits `ToolStop` with `blocked_by` metadata + `ExtensionActed` to SessionEvent
- An extension that transforms a result → core emits the transformed `ToolStop` with `transformed_by` metadata + `ExtensionActed` to SessionEvent
- An extension that injects messages → core emits `InferenceStart` with `messages_transformed_by` metadata + `ExtensionActed` to SessionEvent
- An extension that just observes (fire-and-forget handlers) → no automatic telemetry for observes, they're invisible by design. If an extension wants to be observable for its observations, it can emit its own telemetry (it has access to the event data).

---

## 5. Open Design Questions

### Q1: Decision Types — Making Invalid States Unrepresentable

**Problem:** The current stack functions return bare values (`Result(Nil, String)`, `ToolResultEvent`). These lose attribution (WHICH extension acted) and allow impossible states.

For example, a `ToolStop` event with both `blocked_by: Some("guard")` AND `result: "{\"echo\":\"hi\"}"` is nonsensical — if the tool was blocked, it never ran, so there's no real result.

**Proposal:** Stack functions should return **decision types** that make the outcome and attribution inseparable:

```gleam
/// What the extension stack decided about a tool call.
/// These states are mutually exclusive by construction.
pub type ToolCallDecision {
  /// All extensions allowed the tool to proceed.
  ToolAllowed
  /// An extension blocked the tool. It did NOT execute.
  ToolBlocked(extension_name: String, reason: String)
}

/// What the extension stack decided about a tool result.
pub type ToolResultDecision {
  /// No extension modified the result.
  ResultUnchanged(original_event: ToolResultEvent)
  /// One or more extensions transformed the result.
  ResultTransformed(
    final_event: ToolResultEvent,
    /// Names of extensions that transformed, in order applied.
    transformers: List(String),
  )
}

/// What the extension stack decided about inference messages.
pub type MessagesDecision {
  /// No extension modified the messages.
  MessagesUnchanged(original: List(Message))
  /// One or more extensions replaced the messages.
  MessagesReplaced(
    final_messages: List(Message),
    transformers: List(String),
  )
}
```

Then `core.gleam` pattern-matches on the decision:
```gleam
case decide_tool_call(stack, event) {
  ToolAllowed -> // execute tool, emit normal ToolStart/ToolStop
  ToolBlocked(extension_name, reason) -> // emit ToolBlocked event, create error Tool message
}
```

The `ToolBlocked` variant physically cannot coexist with a tool execution result. The type prevents the impossible state.

**Open sub-question:** For `ToolResultDecision`, should `ResultUnchanged` wrap the event or just return the original list? Wrapping is more uniform but adds indirection. Leaning toward wrapping for consistency.

### Q2: How Much Attribution to Capture in Telemetry Events

The `:telemetry` channel carries string-keyed dicts. Options:

**Option A: Add optional fields to existing events**
```gleam
ToolStop(
  ...
  blocked_by: Option(String),       // extension name if blocked
  block_reason: Option(String),     // why
  transformed_by: Option(String),   // comma-separated extension names
)
```
Pros: No new event types. Existing consumers see richer data.
Cons: `blocked_by` and `transformed_by` are mutually exclusive (a blocked tool has no result to transform), but both are `Option(String)`. Two `Option`s can both be `Some` — not impossible-state-proof at the telemetry level (but the Gleam decision types prevent it upstream, so the telemetry is just a projection).

**Option B: Split into separate event variants**
```gleam
ToolExecuted(tool_name, tool_call_id, duration_ms, result, transformed_by)
ToolBlocked(tool_name, tool_call_id, extension_name, reason)
```
Pros: Impossible states are unrepresentable. Each variant carries only relevant fields.
Cons: More variants. Consumers need to handle more cases. Breaking change to the Event type.

**Leaning toward Option A** — the decision types in Gleam enforce correctness upstream. Telemetry events are a lossy projection for external consumers. The small imprecision at the projection layer is acceptable because the source of truth (the decision type) is sound. And adding optional fields is non-breaking for existing telemetry consumers who ignore unknown keys.

### Q3: ExtensionActed in SessionEvent

The SessionEvent channel (rich, pig-specific) should get a new variant for full audit trail:

```gleam
/// An extension took a non-trivial action during the agent loop.
ExtensionActed(
  extension_name: String,
  hook: ExtensionHook,
  action: ExtensionActionDetail,
)
```

Where `ExtensionHook` and `ExtensionActionDetail` encode what happened:
```gleam
pub type ExtensionHook {
  HookToolCall
  HookToolResult
  HookBeforeInference
}

pub type ExtensionActionDetail {
  BlockedTool(tool_name: String, reason: String)
  TransformedToolResult(tool_name: String, tool_call_id: String)
  ReplacedMessages(count_before: Int, count_after: Int)
}
```

This gives the session writer a complete, typed timeline. The terminal printer can render annotations. OTel exporter can create child spans.

**Open sub-question:** Should fire-and-forget handlers (`on_after_inference`, `on_error`, `on_complete`) generate `ExtensionActed` events? Probably NOT — these are observation-only and the extension is free to do its own logging. `ExtensionActed` should only fire when an extension materially altered the agent's execution path.

### Q4: Blocked Tool → What Message Does the LLM See?

When an extension blocks a tool call, the LLM needs a `Tool` message in the conversation history so it can adapt. Options:

**Option A: Error Tool message** (what pi does)
```gleam
Tool(tool_call_id: "c1", content: "Tool blocked by extension 'safety-guard': dangerous command")
```
The `is_error` equivalent is baked into the content string. Simple, LLM adapts.

**Option B: Dedicated message type**
Add a variant to `Message` for blocked tools. Overkill — the LLM just needs text.

**Leaning toward Option A.** The Tool message with descriptive error text is what pi does and it works. The extension name and reason are included so the LLM can explain to the user what happened.

### Q5: Extension Stack in AgentConfig — Mutable or Immutable?

Extensions are currently immutable values. But what if an extension wants to track state across turns (e.g., "count of blocked tools")?

**Option A: Extensions are pure functions. No state.**
If you need state, wrap it in an OTP actor outside the extension and close over the subject in your handler. The extension system doesn't manage state.

**Option B: Extension receives and returns state.**
```gleam
on_tool_call: fn(state, event) -> #(state, ToolCallAction)
```
This makes the stack a stateful fold. More complex, but self-contained.

**Leaning toward Option A.** Simpler. Stateful extensions are an advanced use case that can be built on top of the pure foundation. The pure API is the 80/20.

---

## 6. Integration Points in Existing Code

### `agent/state.gleam`

`AgentConfig` needs a new field:
```gleam
AgentConfig(
  ...
  extension_stack: ExtensionStack,
)
```
With a default of `extension.empty_stack()` and a setter `with_extension_stack(config, stack)`.

### `agent/core.gleam`

The `step()` function needs to:
1. Call `transform_messages(stack, BeforeInferenceEvent(...))` before calling the provider
2. Call `notify_after_inference(stack, AfterInferenceEvent(...))` after getting the provider response
3. Call `notify_error(stack, ErrorEvent(...))` on provider error

The `execute_tools_and_advance()` function needs to:
1. For each tool call: call `decide_tool_call(stack, ToolCallEvent(...))`
   - If `ToolAllowed`: execute normally, then call `decide_tool_result(stack, ToolResultEvent(...))` 
   - If `ToolBlocked(extension_name, reason)`: create error Tool message, emit enriched events
2. For allowed tools that executed: call `decide_tool_result(stack, ToolResultEvent(...))`
   - Use `ToolResultDecision` to determine final content and attribution

The `run_to_completion()` function needs to:
1. Call `notify_complete(stack, CompleteEvent(...))` on successful completion

### `agent/parallel.gleam`

Same lifecycle hooks as `core.gleam`, but tool calls run in parallel processes. The extension decisions still happen sequentially before spawning (for `decide_tool_call`) and after collecting results (for `decide_tool_result`).

### `obs/events.gleam`

1. Enrich `ToolStop` with optional `blocked_by` and `transformed_by` fields
2. Add `ExtensionActed` variant to `SessionEvent`
3. Add `ExtensionHook` and `ExtensionActionDetail` types

### `obs/session.gleam`

Handle `ExtensionActed` in `format_event()` — write a JSONL entry with extension name, hook, and action detail.

### `obs/terminal.gleam`

Handle `ExtensionActed` in `format_event()` — render a human-readable line like `🛡️ [safety-guard] Blocked bash: dangerous command`.

### `pig.gleam`

Add builder functions:
```gleam
pub fn with_extension(config, ext) -> PigConfig
pub fn with_extensions(config, exts) -> PigConfig
```

These create/update the `ExtensionStack` in the underlying `AgentConfig`.

---

## 7. Usage Examples

### Safety Guard — Block dangerous commands

```gleam
let safety =
  extension.new("safety-guard")
  |> extension.on_tool_call(fn(event) {
    case event.tool_name {
      "bash" ->
        case string.contains(event.arguments_json, "rm -rf") {
          True -> extension.block_tool("Dangerous command blocked by safety guard")
          False -> extension.allow_tool()
        }
      _ -> extension.allow_tool()
    }
  })

let config =
  pig.new(provider)
  |> pig.with_extension(safety)
```

**What gets emitted automatically (extension author does nothing):**
- Telemetry: `ToolStop(blocked_by: Some("safety-guard"), block_reason: Some("Dangerous command..."))`
- SessionEvent: `ExtensionActed(extension_name: "safety-guard", hook: HookToolCall, action: BlockedTool("bash", "Dangerous command..."))`
- LLM sees: `Tool(tool_call_id: "c1", content: "Tool blocked by extension 'safety-guard': Dangerous command blocked by safety guard")`

### Audit Logger — Observe all inference calls

```gleam
let logger =
  extension.new("audit-log")
  |> extension.on_after_inference(fn(event) {
    io.println(
      "[audit] model=" <> event.model
      <> " duration=" <> int.to_string(event.duration_ms) <> "ms"
    )
  })

let config =
  pig.new(provider)
  |> pig.with_extension(logger)
```

**What gets emitted:** Nothing extra. This is a fire-and-forget observer. If the extension author wants observability, they emit their own telemetry inside their handler.

### Result Sanitizer — Strip sensitive data from tool results

```gleam
let sanitizer =
  extension.new("pii-scrubber")
  |> extension.on_tool_result(fn(event) {
    case event.is_error {
      True -> extension.keep_result()
      False ->
        extension.replace_result(
          content: scrub_pii(event.result),
          is_error: False,
        )
    }
  })
```

**What gets emitted automatically:**
- Telemetry: `ToolStop(transformed_by: Some("pii-scrubber"), result: "<scrubbed>")` 
- SessionEvent: `ExtensionActed(extension_name: "pii-scrubber", hook: HookToolResult, action: TransformedToolResult("read", "c1"))`

### Context Injector — Add dynamic context before inference

```gleam
let context_enricher =
  extension.new("context-enricher")
  |> extension.on_before_inference(fn(event) {
    extension.replace_messages([
      message.System("Current time: " <> get_current_time()),
      ..event.messages,
    ])
  })
```

**What gets emitted automatically:**
- SessionEvent: `ExtensionActed(extension_name: "context-enricher", hook: HookBeforeInference, action: ReplacedMessages(count_before: 3, count_after: 4))`

---

## 8. Testing Strategy

Per `TESTING_STRATEGY.md`:

- **Pure functions:** All extension logic is `fn(Event) -> Action`. Test with value-in, value-out.
- **Stack composition:** Test `decide_tool_call`, `decide_tool_result`, `transform_messages` directly — no OTP processes needed.
- **Integration with core:** Use `check_scenario` harness with extensions registered in the config.
- **No mocks needed:** Extensions are functions. Create test extensions inline.
- **Decision types are testable:** Pattern match on `ToolBlocked(extension_name:, reason:)` to assert both values in one match.
- **Telemetry assertions:** Use existing `capture_scenario` harness to verify enriched `ToolStop` events carry `blocked_by` / `transformed_by`.
- **SessionEvent assertions:** Verify `ExtensionActed` variants appear in session writer output.

```gleam
// Example: decision type test
pub fn decision_carries_attribution_test() {
  let blocker =
    extension.new("guard")
    |> extension.on_tool_call(fn(_) { extension.block_tool("nope") })
  let stack = extension.stack([blocker])
  let event = ToolCallEvent(tool_name: "bash", tool_call_id: "1", arguments_json: "{}")
  
  let decision = extension.decide_tool_call(stack, event)
  decision == ToolBlocked(extension_name: "guard", reason: "nope")
}

// Example: integration test with enriched telemetry
pub fn blocked_tool_emits_enriched_telemetry_test() {
  let blocker =
    extension.new("guard")
    |> extension.on_tool_call(fn(e) {
      case e.tool_name {
        "boom" -> extension.block_tool("blocked")
        _ -> extension.allow_tool()
      }
    })
  let tc = message.ToolCall(id: "c1", name: "boom", arguments_json: "{}")
  let tool_resp = message.Assistant("", [tc], None)
  let final = message.Assistant("tool was blocked", [], None)
  
  let #(result, events) = harness.capture_scenario_with_extensions(
    "use boom",
    [tool_resp, final],
    [],
    "test-model",
    [blocker],
  )
  // Verify ToolStop carries blocked_by
  let assert Ok(events.ToolStop(blocked_by:)) = find_tool_stop(events)
  blocked_by == Some("guard")
}
```

---

## 9. What We're NOT Building (Yet)

Deferred, matching pi's pattern of growing incrementally:

- **Custom tools via extensions** — pig already has `pig.with_tool()`. Extensions can compose tools externally.
- **Extension-provided commands/shortcuts** — pig has no command system yet.
- **Extension loading from filesystem** — extensions are Gleam values constructed in code. No dynamic module loading on the BEAM.
- **Mutable extension state** — Use an OTP actor alongside the extension if you need stateful tracking.
- **Provider registration from extensions** — Extensions can't swap out the provider mid-loop.
- **Session lifecycle events** (pi's `session_start`, `session_shutdown`, etc.) — pig doesn't have session management yet.

---

## 10. File Map

### Already Created

| File | Purpose |
|------|---------|
| `src/pig/extension.gleam` | Core types, builder functions, stack composition |
| `test/pig/extension_test.gleam` | 33 unit tests for builder + stack |

### Needs Modification

| File | Change |
|------|--------|
| `src/pig/agent/state.gleam` | Add `extension_stack` field to `AgentConfig` |
| `src/pig/agent/core.gleam` | Wire extension calls at each lifecycle point |
| `src/pig/agent/parallel.gleam` | Wire extension calls for parallel tool execution |
| `src/pig/obs/events.gleam` | Enrich `ToolStop`, add `ExtensionActed` to `SessionEvent` |
| `src/pig/obs/session.gleam` | Handle `ExtensionActed` in `format_event` |
| `src/pig/obs/terminal.gleam` | Handle `ExtensionActed` in `format_event` |
| `src/pig.gleam` | Add `with_extension` / `with_extensions` builder functions |
| `test/support/harness.gleam` | Add `check_scenario_with_extensions`, `capture_scenario_with_extensions` |

### Needs Creation

| File | Purpose |
|------|---------|
| `test/pig/agent/extension_integration_test.gleam` | Integration tests: extensions wired through core loop |
| `test/pig/obs/extension_observability_test.gleam` | Test enriched telemetry and ExtensionActed events |

---

## 11. Implementation Order

1. **Refactor `extension.gleam`** — Change stack functions to return decision types (`ToolCallDecision`, `ToolResultDecision`, `MessagesDecision`). Update existing tests.
2. **Enrich `obs/events.gleam`** — Add optional `blocked_by`/`block_reason`/`transformed_by` to `ToolStop`. Add `ExtensionHook`, `ExtensionActionDetail`, and `ExtensionActed` to `SessionEvent`.
3. **Update `agent/state.gleam`** — Add `extension_stack` to `AgentConfig`.
4. **Wire `agent/core.gleam`** — Call extension stack at each lifecycle point, emit enriched telemetry and SessionEvents.
5. **Wire `agent/parallel.gleam`** — Same hooks, parallel execution path.
6. **Wire `pig.gleam`** — Add `with_extension` / `with_extensions`.
7. **Update consumers** — `obs/session.gleam` and `obs/terminal.gleam` handle `ExtensionActed`.
8. **Write integration tests** — Via harness, verify end-to-end behavior with enriched telemetry assertions.
