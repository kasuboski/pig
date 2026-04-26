# Design Document: `pig`

A library for building resilient, observable, and skill-augmented AI agents on the BEAM.

---

## 1. High-Level Goals
*   **Composition over Configuration:** Build specialized agents by composing discrete skills and tools.
*   **Provider Agnostic:** Normalize interactions across OpenAI, Anthropic, and local models.
*   **Resilient by Default:** Leverage OTP supervision trees to ensure tool failures or API timeouts don't crash the system.
*   **Deep Observability:** Native integration with BEAM `:telemetry` for world-class tracing and debugging.
---

## 2. System Architecture

The library is organized into layered modules:

1.  **`pig/ai` (The Brain):** Normalizes various LLM APIs into a unified `Provider` interface.
2.  **`pig/agent` (The Nervous System):** An OTP Actor that manages the conversation state, message history, and the execution loop.
3.  **`pig/skill` (The Knowledge):** A system for loading Markdown-based instructions and exposing them to the agent via discovery tools.
4.  **`pig/tool` (The Hands):** A typed interface for defining functions the LLM can invoke.
5.  **`pig/obs` (The Senses):** Telemetry-based observability and session persistence (JSONL).

---

## 3. Module Definitions

### 3.1 `pig/ai`: Provider Normalization
A unified type system for messages and a common interface for model providers.

*   **Types:**
    *   `Message`: A union type of `User`, `Assistant` (containing optional `ToolCalls` and `Thinking` blocks), `Tool` (results), and `System`.
    *   `ToolDefinition`: The JSON Schema representation of a tool.
*   **Interface:** A provider is a function: `fn(List(Message), List(ToolDefinition)) -> Result(Message, AiError)`.

### 3.2 `pig/agent`: The Stateful Actor
The Agent is a `gleam/otp/actor`. It maintains an internal state including message history, active skills, and available tools.

*   **The Loop:** A recursive process that:
    1.  Sends the current context to the Provider.
    2.  Parses the response for `ToolCalls`.
    3.  Executes tools (in parallel via `gleam/otp/task`).
    4.  Appends results to history and recurses until a final answer is reached.

### 3.3 `pig/skill`: Logic-less Knowledge
A Skill is a directory on disk containing a `README.md` and supplementary files.
*   **Librarian Tool:** The library provides a built-in tool that allows the agent to `read_skill(name: String)`.
*   **Discovery:** At startup, the library parses skill directories to extract names/descriptions and injects them into the System Prompt.

### 3.4 `pig/obs`: Telemetry & Persistence
*   **Telemetry:** Emits events via `:telemetry` at every step (`InferenceStarted`, `ToolExecuted`, `TokenReceived`).
*   **Session Store:** An asynchronous process that listens to telemetry events and streams them to a `.jsonl` file for after-the-fact analysis and "time-travel" debugging.

---

## 4. The Execution Loop Detail

When `agent.run(prompt)` is called:
1.  **Entry:** The prompt is wrapped in a `User` message and appended to history.
2.  **Inference:** The actor calls the configured `Provider`.
3.  **Branching:**
    *   **If Content:** The loop completes, returning the response.
    *   **If ToolCalls:** 
        *   The actor spawns `Task`s for each tool call.
        *   Results are collected into `Tool` messages.
        *   The actor updates history and calls itself (Step 2).
4.  **Interruption:** The actor checks its mailbox for `Stop` or `Interrupt` signals between every iteration.

---

## 5. Example Usage

### 5.1 Basic Agent with Skills
```gleam
import pig
import pig/ai/anthropic
import pig/skill
import pig/tools/file_system

pub fn main() {
  // 1. Load data-driven skills from the filesystem
  let gleam_expert = skill.load("./skills/gleam_expert")
  
  // 2. Configure the agent
  let agent_config = pig.new(anthropic.claude_3_5_sonnet(api_key: "sk-..."))
    |> pig.with_skill(gleam_expert)
    |> pig.with_tool(file_system.read_only())
    |> pig.with_persistence("./sessions")

  // 3. Start the agent process
  let assert Ok(agent) = pig.start(agent_config)

  // 4. Run a task
  let result = pig.run(agent, "Explain the supervisor pattern in this codebase")
}
```

### 5.2 Observability & Telemetry
```gleam
import pig/obs/terminal
import pig/obs/otel

pub fn setup_observability() {
  // Attach a pretty-print logger to the terminal
  terminal.attach()
  
  // Bridge events to OpenTelemetry for Jaeger/Honeycomb
  otel.attach()
}
```

---

## 6. BEAM & OTP Considerations

### 6.1 Supervision Trees
The library should be used within a supervision tree.
*   **Agent Supervisor:** Manages individual agent processes.
*   **Persistence Supervisor:** Manages the JSONL writer and any DB connections.
*   **Tool Isolation:** Tools are executed in transient Task processes. If a tool crashes (e.g., a regex engine hangs or a file is locked), the Agent process remains stable and receives an `Error` result it can report to the LLM.

### 6.2 Parallelism
The loop must execute multiple tool calls in parallel using BEAM processes. If an LLM requests 5 files, they are read concurrently, significantly reducing "Wall Clock" time compared to sequential processing.

### 6.3 State Immutability
Every step of the agent's "thinking" results in a new, immutable `AgentState`. This allows for:
*   **Snapshots:** Saving the state at any point.
*   **Branching:** Exploring two different responses from the same point in a conversation by spawning two different actors with the same state.

---

## 7. Customization Points (UX)

Library users add "Logic and Ideas" through:
1.  **Custom Tools:** Providing Gleam functions that the agent can call.
2.  **Custom Middleware:** Functions that intercept `AgentEvents` (e.g., a "Safety Guard" that blocks specific bash commands).
3.  **Skill Markdown:** Refining the agent's behavior and domain knowledge by editing Markdown files without touching code.
4.  **Custom Session Stores:** Implementing the `SessionStore` behavior to save data to Postgres, Redis, or a custom API.

---

## 8. Summary of Interface Decisions

*   **No Classes:** Use Records and Modules.
*   **Explicit over Magic:** No auto-discovery of files; the user explicitly points the library to skill directories.
*   **Async Persistence:** Logging and saving sessions must never block the LLM inference or tool execution.
*   **Normalized Messaging:** Whether using Claude or GPT, the user only ever interacts with the `pig/ai.Message` type.
