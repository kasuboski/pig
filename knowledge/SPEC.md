# Design Document: `pig`

A library for building resilient, observable, and skill-augmented AI agents on the BEAM.

---

## 1. High-Level Goals
*   **Composition over Configuration:** Build specialized agents by composing discrete skills, tools, and hooks.
*   **Provider Agnostic:** Normalize interactions across any OpenAI-compatible LLM API.
*   **Resilient by Default:** Leverage OTP supervision trees to ensure tool failures or API timeouts don't crash the system.
*   **Deep Observability:** Dispatcher-actor pattern with BEAM `:telemetry` for world-class tracing and debugging.

---

## 2. System Architecture

The library is organized into layered modules:

1.  **`pig/ai` (The Brain):** Normalizes LLM APIs into a unified `Provider` interface.
2.  **`pig/agent` (The Nervous System):** An OTP Actor that manages conversation state, message history, and the execution loop.
3.  **`pig/skill` (The Knowledge):** A system for loading Markdown-based instructions and exposing them to the agent via a librarian tool.
4.  **`pig/tool` (The Hands):** A typed interface for defining functions the LLM can invoke.
5.  **`pig/workspace` (The Memory):** A SQLite-backed virtual filesystem and key-value store for agent persistence.
6.  **`pig/hooks` (The Guardrails):** Composable lifecycle hooks that mediate inference, tool calls, and errors.
7.  **`pig/obs` (The Senses):** A dispatcher-actor pattern that emits telemetry and fans out structured `SessionEvent` values to consumers.

---

## 3. Module Definitions

### 3.1 `pig/ai`: Provider Normalization
A unified type system for messages and a common interface for model providers.

*   **Types:**
    *   `Message`: A union type of `User`, `Assistant` (containing optional `ToolCalls` and `Thinking` blocks), `Tool` (results), and `System`.
    *   `ToolDefinition`: The JSON Schema representation of a tool.
    *   `InferenceResult`: Wraps a `Message` with `InferenceMetadata` (response ID, model, finish reason, token counts).
*   **Interface:** A provider is a function: `fn(List(Message), List(ToolDefinition)) -> Result(InferenceResult, AiError)`.

### 3.2 `pig/agent`: The Stateful Actor
The Agent is a `gleam/otp/actor`. It maintains internal state including message history, active skills, available tools, and hook list.

*   **The Loop:** A recursive process that:
    1.  Sends the current context to the Provider.
    2.  Parses the response for `ToolCalls`.
    3.  Executes tools (in parallel via `gleam/otp/task`).
    4.  Appends results to history and recurses until a final answer is reached.

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
Hooks intercept agent lifecycle events and return actions that control behavior.
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
1.  **Entry:** The prompt is wrapped in a `User` message and appended to history.
2.  **Inference:** The actor calls the configured `Provider`.
3.  **Branching:**
    *   **If Content:** The loop completes, returning the response.
    *   **If ToolCalls:**
        *   The actor spawns `Task`s for each tool call.
        *   Results are collected into `Tool` messages.
        *   The actor updates history and calls itself (Step 2).
4.  **Stop:** The actor checks its mailbox for `Stop` signals between every iteration.

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
*   **Tool Isolation:** Tools are executed in transient Task processes. If a tool crashes, the Agent process remains stable and receives an `Error` result it can report to the LLM.

### 6.2 Parallelism
The loop executes multiple tool calls in parallel using BEAM processes. If an LLM requests 5 files, they are read concurrently, significantly reducing wall-clock time.

### 6.3 State Immutability
Every step of the agent's "thinking" results in a new, immutable `AgentState`. This allows for:
*   **Snapshots:** Saving the state at any point.
*   **Branching:** Exploring two different responses from the same point in a conversation by spawning two different actors with the same state.

---

## 7. Customization Points (UX)

Library users extend behavior through:
1.  **Custom Tools:** Providing Gleam functions that the agent can call.
2.  **Hooks:** Composable lifecycle hooks that can block tools, replace messages, or transform results.
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
*   **Hooks over Middleware:** Composable hook functions return typed actions rather than opaque middleware chains.
