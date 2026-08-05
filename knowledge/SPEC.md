# Design Document: `pig`

A library for building resilient, observable, and skill-augmented AI agents on the BEAM.

---

## 1. High-Level Goals
*   **Composition over Configuration:** Build specialized agents by composing discrete skills, tools, and hooks.
*   **Provider Agnostic:** Normalize interactions across any OpenAI-compatible LLM API.
*   **Resilient by Default:** Leverage OTP supervision trees to ensure tool failures or API timeouts don't crash the system.
*   **Deep Observability:** Dispatcher-actor pattern with BEAM `:telemetry` for world-class tracing and debugging.
*   **Sans-IO Core:** The agent core is a pure state machine — `(state, msg) → (state, effects)` — with all IO in a separate runtime interpreter. Testable in microseconds, no mocks needed.

---

## 2. System Architecture

The library is organized into layered modules:

1.  **`pig/ai` (The Brain):** Normalizes LLM APIs into a unified `Provider` interface.
2.  **`pig/agent` (The Nervous System):** A pure state machine (`update.gleam`) plus an OTP runtime interpreter (`runtime.gleam`). The core has zero IO — no provider calls, no tool execution, no telemetry, no hooks. The runtime interprets effect declarations against the real world.
3.  **`pig/skill` (The Knowledge):** A system for loading Markdown-based instructions and exposing them to the agent via a librarian tool.
4.  **`pig/tool` (The Hands):** A typed interface for defining functions the LLM can invoke.
5.  **`pig/workspace` (The Memory):** A SQLite-backed virtual filesystem and key-value store for agent persistence.
6.  **`pig/hooks` (The Guardrails):** Composable lifecycle hooks that mediate inference, tool calls, and errors. Hooks run in the runtime as middleware on effects — the core is unaware of them.
7.  **`pig/obs` (The Senses):** A dispatcher-actor pattern that emits telemetry and fans out structured `SessionEvent` values to consumers. All events are produced by the runtime, not the core.

---

## 3. Module Definitions

### 3.1 `pig/ai`: Provider Normalization
A unified type system for messages and a common interface for model providers.

*   **Types:**
    *   `Message`: A union type of `User`, `Assistant` (containing optional `ToolCalls` and `Thinking` blocks), `Tool` (results), and `System`.
    *   `ToolDefinition`: The JSON Schema representation of a tool.
    *   `InferenceResult`: Wraps a `Message` with `InferenceMetadata` (response ID, model, finish reason, token counts).
    *   `ThinkingLevel`: Provider-neutral reasoning effort (`Off`, `Minimal`, `Low`, `Medium`, `High`, `XHigh`, or `Max`).
*   **Interface:** A provider is a function: `fn(List(Message), List(ToolDefinition)) -> Result(InferenceResult, AiError)`. Provider constructors capture model-specific request configuration such as thinking level; the OpenAI Chat Completions provider maps it to `reasoning_effort`, while the Responses provider maps it to `reasoning.effort`.

### 3.2 `pig/agent`: Sans-IO State Machine + Runtime

The agent is split into two layers:

**Pure core (`pig/agent/update.gleam`):** A state machine with the signature `update(state, msg) -> StepResult(msg)`. It has no IO — no provider calls, no tool execution, no telemetry, no hooks. Given the same `(state, msg)`, it always produces the same `(state, effects)`. This makes it trivially testable with zero mocks.

The core operates on three types:

*   **`AgentMsg`:** `UserPrompt(String)`, `ProviderResponded(Result(Message, AiError))`, `ToolResults(List(#(ToolCall, Result(Json, ToolError))))`.
*   **`Effect(msg):** `CallProvider(messages, tools, on_response)` and `ExecuteTools(calls, on_results)`. Effects are declarations of intent — the core says "call this provider" or "execute these tools" but never does it.
*   **`StepResult(msg):** `Done(state, message)`, `Continue(state, effects)`, `Failed(state, error)`.

**Runtime interpreter (`pig/agent/runtime.gleam`):** An OTP actor that holds the provider function, tool registry, hooks list, and dispatcher subject. The runtime loop:

1.  Receives a `Run(prompt)` message.
2.  Calls `update(state, UserPrompt(prompt))` — pure.
3.  For each effect returned, applies hooks as middleware, then executes the effect.
4.  Produces `SessionEvent` values from hook processing and effect execution.
5.  Feeds results back as new `AgentMsg` values and loops.

### 3.3 `pig/skill`: Logic-less Knowledge
A Skill is a directory on disk containing a `SKILL.md` (with YAML frontmatter for name/description) and supplementary files.
*   **Librarian Tool:** The library provides a built-in tool (`skill/librarian`) that allows the agent to read skill contents by name.
*   **Discovery:** Skills are loaded explicitly via `skill.load(path)` and registered on the agent config.

### 3.4 `pig/workspace`: Agent Persistence
A SQLite-backed abstraction providing:
*   **Virtual Filesystem:** Read, write, delete, list, grep files in a virtual directory tree.
*   **Key-Value Store:** Remember and recall string values by key.
*   **Tool Generation:** `workspace.all_tools(connection)` returns a list of tools the LLM can invoke to interact with the workspace.

### 3.5 `pig/hooks`: Lifecycle Mediation
Hooks intercept agent lifecycle events and return actions that control behavior. Hooks run in the runtime as middleware on effects — the core is pure and has no knowledge of hooks.
*   **Hook Points:** `on_before_inference`, `on_after_inference`, `on_tool_call`, `on_tool_result`, `on_error`, `on_complete`, `on_session_start`, `on_session_shutdown`.
*   **Actions:** Hooks return typed actions — `AllowTool`/`BlockTool`, `KeepResult`/`ReplaceResult`, `KeepMessages`/`ReplaceMessages`.
*   **Composition:** Multiple hooks chain together. The first hook to block or replace wins.

### 3.6 `pig/obs`: Telemetry & Persistence
The observability system uses a dispatcher-actor pattern.
*   **Dispatcher:** A single actor that receives `SessionEvent` values, always projects lightweight `:telemetry` events, then fans out the full event to registered consumers.
*   **Consumers:** Pluggable actors that process events — session writer (JSONL), terminal printer, and future OTel exporter.
*   **Optional by Construction:** When no dispatcher is configured, all emission is a silent no-op. The agent never crashes due to missing telemetry.

---

## 4. The Execution Loop Detail

When `pig.run(agent, prompt)` is called:
1.  **Entry:** The runtime receives `Run(prompt)`, wraps it in `UserPrompt`, calls `update(state, UserPrompt(prompt))`. The core returns `Continue(state, [CallProvider(messages, tools, on_response)])`.
2.  **Inference:** The runtime's effect handler applies `on_before_inference` hooks (may transform messages), calls the provider, fires `on_after_inference` hooks, emits `InferenceStarted`/`InferenceCompleted` events, then feeds the response back as `ProviderResponded`.
3.  **Branching:** The core processes `ProviderResponded`:
    *   **If text:** Returns `Done(state, message)`. The runtime returns the message to the caller.
    *   **If tool calls:** Returns `Continue(state, [ExecuteTools(calls, on_results)])`. The runtime applies `on_tool_call` hooks (allow/block), executes allowed tools in parallel, applies `on_tool_result` hooks, emits events, then feeds results back as `ToolResults`.
4.  **Loop:** The runtime continues calling `update` with each response until it gets `Done` or `Failed`.
5.  **Circuit breaker:** If `exceeded_max_iterations` is true, the core returns `Failed` instead of `Continue`.

---

## 5. Example Usage

### 5.1 Basic Agent with Skills and Workspace
```gleam
import pig
import pig/ai/openai
import pig/skill
import pig/workspace

pub fn main() {
  // 1. Load data-driven skills from the filesystem
  let gleam_expert = skill.load("./skills/gleam_expert")

  // 2. Open a workspace for the agent
  let assert Ok(ws) = workspace.open("./data/agent_workspace.db")

  // 3. Configure the agent
  let agent_config = pig.new(openai.provider(api_key: "sk-...", model: "gpt-4o"))
    |> pig.with_skill(gleam_expert)
    |> pig.with_tools(workspace.all_tools(workspace.connection(ws)))
    |> pig.with_session_writer("./sessions")

  // 4. Start the agent process
  let assert Ok(agent) = pig.start(agent_config)

  // 5. Run a task
  let result = pig.run(agent, "Explain the supervisor pattern in this codebase")
}
```

### 5.2 Observability
```gleam
import pig/obs/terminal

pub fn setup_observability() {
  // Terminal printer shows agent activity on stdout
  // When using supervised start, add terminal as a consumer spec:
  // pig.with_terminal_output(config)
}
```

### 5.3 Supervised Start
```gleam
import pig/supervisor
import pig/obs/session
import pig/obs/terminal

pub fn main() {
  let config = pig.new(openai.provider(api_key: "sk-...", model: "gpt-4o"))
    |> pig.with_session_writer("./sessions")
    |> pig.with_terminal_output()

  let assert Ok(sup) = supervisor.start_supervised(
    pig.agent_config(config),
    [],
  )

  let result = supervisor.run(sup, "Hello")
}
```

---

## 6. BEAM & OTP Considerations

### 6.1 Supervision Trees
The library provides two start modes:
*   **Standalone** (`pig.start`): Starts dispatcher and consumers individually. Good for simple usage.
*   **Supervised** (`supervisor.start_supervised`): Builds a nested OTP static supervision tree:
    ```text
    AppSupervisor (OneForOne)
      ├── EventSupervisor (OneForAll)
      │     ├── event_dispatcher (named)
      │     ├── session_writer (named)
      │     └── terminal_printer (named)
      └── pig_agent (named)
    ```
*   **Tool Isolation:** Tools are executed in spawned BEAM processes (one per tool, collected in order). If a tool crashes, the runtime catches the timeout and returns an error result — the agent stays alive.

### 6.2 Parallelism
The runtime's `ExecuteTools` handler spawns one BEAM process per allowed tool call and collects results in order. This is a runtime implementation detail — the core just says "execute these tools" via the `ExecuteTools` effect. The runtime decides concurrency.

### 6.3 State Immutability
Every step of the agent's "thinking" results in a new, immutable `AgentState`. The pure `update` function never mutates — it returns a new state. This allows for:
*   **Snapshots:** Saving the state at any point.
*   **Branching:** Exploring two different responses from the same point in a conversation by spawning two different actors with the same state.
*   **Instant testing:** `(state, msg) → (state, effects)` with zero IO.

---

## 7. Customization Points (UX)

Library users extend behavior through:
1.  **Custom Tools:** Providing Gleam functions that the agent can call.
2.  **Hooks:** Composable lifecycle hooks that can block tools, replace messages, or transform results. Applied by the runtime as middleware on effects.
3.  **Skill Markdown:** Refining the agent's behavior and domain knowledge by editing Markdown files without touching code.
4.  **Workspace:** SQLite-backed persistence for file I/O and key-value storage.
5.  **Custom Consumers:** Registering actors that receive `SessionEvent` values — enables OTel exporters, custom analytics, or alternative session stores.

---

## 8. Summary of Interface Decisions

*   **No Classes:** Use Records and Modules.
*   **Explicit over Magic:** No auto-discovery of files; the user explicitly points the library to skill directories.
*   **Async Persistence:** Logging and saving sessions must never block the LLM inference or tool execution. Fire-and-forget `process.send` throughout.
*   **Normalized Messaging:** Regardless of provider, the user only ever interacts with the `pig/ai.Message` type.
*   **Optional Observability:** No dispatcher configured means zero overhead. Observability never crashes the agent.
*   **Sans-IO Core:** The agent logic is a pure function `(state, msg) -> StepResult(msg)`. All IO lives in the runtime interpreter. The core has no imports for HTTP, process spawning, telemetry, or hooks.
