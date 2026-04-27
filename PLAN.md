# `pig` — TDD Implementation Plan

A step-by-step, test-first plan for building the `pig` library. Every task starts with the test, then describes the implementation. The plan builds layers bottom-up so each layer has its dependencies satisfied.

**Key References:**
- `knowledge/SPEC.md` — Full system architecture and module contracts
- `knowledge/TESTING_STRATEGY.md` — Purity, check idioms, data-driven testing rules

**Resolved Decisions:**
1. **HTTP:** Use `gleam_http` + `gleam_httpc` for provider API calls. Create a thin wrapper `pig/ai/http.gleam` to simplify provider development.
2. **Streaming:** Deferred. Provider interface is request/response only for v1.
3. **Middleware:** Deferred until we have a working base.
4. **Session Stores:** JSONL only for now.
5. **Supervisor:** Export `pig.start_supervised(config)` as the easy path, but every component can also be started standalone for advanced users.
6. **Target:** Erlang only. Set `target = "erlang"` in `gleam.toml`.
7. **Provider v1:** OpenAI-compatible only. Configurable `base_url` + arbitrary model string for inference provider compatibility. No Anthropic provider in v1.
8. **Logging vs Telemetry:** See "Observability Model" section below.
9. **Provider Return Type:** `Provider` returns `Result(InferenceResult, AiError)` — not bare `Result(Message, AiError)`. `InferenceResult` carries the `Message` plus `InferenceMetadata` (response ID, token counts, finish reason, response model). See Phase 9 Task 9.0a.
10. **Agent Identity:** `AgentConfig` carries optional `agent_id`, `agent_name`, `agent_description`, `agent_version`, `provider_name`. All default to `None`. See Phase 9 Task 9.0d.
11. **Two-Channel Observability:** Two first-class event channels. `SessionEvent` carries full content for pig-specific consumers (session writer, terminal, OTel with GenAI semantics). `:telemetry` carries lightweight metrics for BEAM ecosystem integration (LiveDashboard, Telemetry.Metrics, `opentelemetry_telemetry`). See Phase 9 "Event Distribution Architecture".
12. **SessionEvent is canonical for pig consumers.** ALL pig observability modules (session writer, terminal, future OTel exporter) read from `SessionEvent`s. `:telemetry` serves the broader BEAM ecosystem — it is not a bridge, it is a first-class channel for a different audience.

**Observability Model — Two First-Class Channels + Logging:**

pig emits events through two independent channels, each serving a different ecosystem. Neither is a bridge or shim — both are first-class.

| | `SessionEvent` (pig consumers) | `:telemetry` (BEAM ecosystem) | `:logger` (`logging`) |
|---|---|---|---|
| **Audience** | pig-specific consumers | BEAM ecosystem tools (LiveDashboard, Telemetry.Metrics, `opentelemetry_telemetry`, AppSignal) | Library developers (us, debugging `pig` internals) |
| **Content** | Full message content, metadata, tool args/results, token counts | Lightweight metrics (counts, durations, token counts, model name) | Freeform debug text |
| **Examples** | `InferenceCompleted(message, input_messages, token_counts)` | `[:pig, :inference, :stop]` with `%{duration_ms: 150}` | `[debug] pig/ai/http: POST /v1/chat/completions -> 429, retrying` |
| **Transport** | Gleam actor messages (fan-out to registered consumers) | `telemetry.execute/3` (broadcast) | Erlang `:logger` |
| **Consumers** | `pig/obs/session`, `pig/obs/terminal`, future `pig/obs/otel` | Any `:telemetry` handler in the BEAM ecosystem | Console, dev-time log files |
| **Visibility** | User-facing, on when consumers are registered | Always emitted — zero-config for BEAM users | Off by default |
| **Why it exists** | OTel GenAI semantics need full message bodies; pig-specific tooling needs full content | BEAM standard — Phoenix, Ecto, Oban all emit `:telemetry`. Users with existing dashboards get pig metrics for free. | Internal diagnostics only |

**Golden rule: Two first-class channels, zero duplication.**
- `SessionEvent` carries full content (messages, tool args/results, token counts, timing). All pig-specific consumers read from it.
- `:telemetry` carries lightweight metrics (durations, counts, model name). BEAM ecosystem tools consume it natively — pig users get LiveDashboard, Telemetry.Metrics, and generic OTel bridging for free.
- Both are always emitted from the same code paths. Neither is optional or a shim.
- `:logger` (via the `logging` package) is for internal developer diagnostics only: HTTP transport debugging, configuration validation warnings.
- Never duplicate data across channels. If `SessionEvent` covers it, don't also log it.

**Build Order Rationale:**
```
pig/ai types ──► pig/obs events ──► pig/ai http ──► pig/ai/openai ──► pig/tool ──► pig/agent (pure) ──► pig/agent (actor) ──► pig/skill ──► pig (top-level + supervisor) ──► pig/obs persistence + enriched types
```

Types come first (everything depends on `Message` and `AiError`). Telemetry event definitions come next so every subsequent layer can emit events as it's built — observability is not bolted on later. The HTTP wrapper goes before the provider so it has something to build on. The pure agent loop is tested before the OTP wrapper. Skills come after tools since the "librarian" is itself a tool. Phase 9 enriches the provider return type (`InferenceResult`) and adds session persistence as a separate channel from telemetry — this must come after the agent and supervisor are working.

---

## Phase 1: Foundation Types

### Task 1.1 — `pig/ai` Message Types

**Test first:**
```
test/pig/ai/message_test.gleam
```
- Test constructing each message variant: `User("hello")`, `System("you are...")`, `Assistant` with text only, `Assistant` with tool calls, `Assistant` with thinking blocks, `Tool` with a result string and tool call ID.
- Test equality of two identical messages.
- Test that a message's role accessor works (e.g., `user_role`, `assistant_role`).

**Implementation:**
```
src/pig/ai/message.gleam
```
- Define `Message` as a custom type with variants: `User(content)`, `System(content)`, `Assistant(content, tool_calls, thinking)`, `Tool(tool_call_id, content)`.
- Define `ToolCall` type: `ToolCall(id, name, arguments_json)`.
- Define `Thinking` type: `Thinking(content)`.
- Define `Role` type: `User | Assistant | Tool | System`.
- Provide `role(msg)` accessor.

**Helpful:** SPEC §3.1 (Message union type definition)

---

### Task 1.2 — `pig/ai` Error & ToolDefinition Types

**Test first:**
```
test/pig/ai/error_test.gleam
test/pig/ai/tool_definition_test.gleam
```
- Test constructing each `AiError` variant: `ApiError(String)`, `RateLimited`, `Timeout`, `InvalidResponse(String)`.
- Test constructing a `ToolDefinition` with name, description, and JSON schema string.
- Test equality and accessor functions.

**Implementation:**
```
src/pig/ai/error.gleam
src/pig/ai/tool_definition.gleam
```
- `AiError` custom type with variants above.
- `ToolDefinition` record: `ToolDefinition(name: String, description: String, parameters: String)` where `parameters` is a JSON Schema string.

**Helpful:** SPEC §3.1 (ToolDefinition, AiError implied by `Result(Message, AiError)`)

---

### Task 1.3 — `pig/ai` Provider Interface

**Test first:**
```
test/pig/ai/provider_test.gleam
```
- Test that a provider function (a simple Gleam function matching the signature) can be called with a list of messages and tool definitions and returns `Ok(Assistant(...))` or `Error(ApiError(...))`.
- This is testing the *type* is callable — it proves the function signature works. Use a trivial identity/stub provider.
- Test with an empty tool list.
- Test with populated tool list.

**Implementation:**
```
src/pig/ai/provider.gleam
```
- Define the type alias: `Provider` as a function type `fn(List(Message), List(ToolDefinition)) -> Result(Message, AiError)`.
- This module may be small — it's just the type alias and any helpers for composing providers.

**Helpful:** SPEC §3.1 (Provider interface signature)

---

## Phase 2: Observability Foundations

### Task 2.1 — `pig/obs` Telemetry Event Definitions

**Test first:**
```
test/pig/obs/events_test.gleam
```
- Test that each event name is a well-formed list of atoms/strings matching the convention: `pig.inference.start`, `pig.inference.stop`, `pig.inference.exception`, `pig.tool.start`, `pig.tool.stop`, `pig.tool.exception`.
- Test that event metadata structures can be constructed (e.g., `InferenceStartMeta{model, message_count}`, `ToolStartMeta{tool_name, tool_call_id}`).
- These are pure data tests — no actual telemetry attachment.

**Implementation:**
```
src/pig/obs/events.gleam
```
- Define constants/functions for event names.
- Define metadata record types for each event.
- Define `emit_inference_start`, `emit_inference_stop`, `emit_tool_start`, `emit_tool_stop` helper functions that call `telemetry.execute/3` (via Erlang FFI).

**Helpful:** SPEC §3.4, §6 (Telemetry events list); TESTING_STRATEGY §Part II Area: pig/obs

---

### Task 2.2 — `pig/obs` Test Listener / Harness

**Test first:**
```
test/pig/obs/listener_test.gleam
```
- Test that attaching a listener captures events into a list.
- Test that after emitting an event, the listener's captured list grows.
- Test detaching stops capture.

**Implementation:**
```
src/pig/obs/listener.gleam (or test/support/telemetry_capture.gleam)
```
- A test utility that attaches to telemetry events and accumulates them into a process dictionary or ETS table.
- `attach()` -> returns a handle.
- `get_events(handle)` -> returns `List(CapturedEvent)`.
- `detach(handle)` -> cleans up.

**Helpful:** TESTING_STRATEGY §Part II ("Log Assertion Pattern", "Do not use sleep()")

---

## Phase 3: HTTP Layer & Provider Implementations

### Task 3.0 — `pig/ai/http` HTTP Wrapper

**Test first:**
```
test/pig/ai/http_test.gleam
```
- Test that `build_request(url, headers, body)` returns a well-formed `Request` value (pure — no network).
- Test that HTTP error statuses (429, 500, 401) map to the correct `AiError` variants (`RateLimited`, `ApiError`).
- Test that connection errors (timeout, refused) map to `AiError.Timeout` or `AiError.ApiError`.
- Test the actual `post` call as an integration test (separate, opt-in).

**Implementation:**
```
src/pig/ai/http.gleam
```
- Thin wrapper over `gleam_http` + `gleam_httpc`.
- `post(url: String, headers: List(#(String, String)), body: String) -> Result(String, AiError)`
- `build_request/3` — pure function constructing a `gleam/http.Request`.
- `map_http_error` — pure function mapping HTTP error responses → `AiError` variants.
- Uses the `logging` package for internal debug logging (request URL, response status, timing). This is NOT telemetry — it's developer-facing diagnostic output.
- This is the single place provider modules import for HTTP — swapping the client later means changing one file.

**Dependencies to add:** `gleam_http`, `gleam_httpc` in `gleam.toml`

**Helpful:** SPEC §3.1 (Provider interface needs transport)

---

### Task 3.1 — `pig/ai/openai` OpenAI-Compatible Provider

This is the **only** provider for v1. It supports OpenAI's Chat Completions format and is configurable for any compatible inference provider (Ollama, Together, Groq, etc.).

**Test first:**
```
test/pig/ai/openai_test.gleam
test_data/providers/openai_text_response.json
test_data/providers/openai_tool_call_response.json
test_data/providers/openai_error_response.json
test_data/providers/openai_multi_tool_call_response.json
```
- **Golden file tests:** For each fixture JSON file, test that `parse_response(json_string)` returns the correct `Result(Message, AiError)`.
  - Text response → `Ok(Assistant("Hello!", [], None))`
  - Tool call response → `Ok(Assistant("", [ToolCall("id", "function_name", "{...}")], None))`
  - Multi tool call → `Ok(Assistant("", [ToolCall(...), ToolCall(...)], None))`
  - Error response → `Error(ApiError("..."))`
- **Request builder tests:** Test `build_request_body(messages, tool_defs)` produces valid JSON matching OpenAI's expected schema (pure).
- **Provider construction tests:** Test that `provider(api_key, model)` and `provider(api_key, model, base_url)` both return a callable `Provider` function. Test that custom `base_url` is used (via captured closure — inspect the built request URL).
- **Error mapping tests:** Test that rate-limit responses (429) map to `Error(RateLimited)`, server errors to `Error(ApiError(...))`, malformed JSON to `Error(InvalidResponse(...))`.

**Implementation:**
```
src/pig/ai/openai.gleam
```
- `OpenAIConfig` record: `OpenAIConfig(api_key: String, model: String, base_url: String)`.
  - Default `base_url`: `"https://api.openai.com/v1"`
  - `model` is a free-form `String` — no hardcoded model list.
- `provider(api_key, model) -> Provider` — convenience constructor with default base URL.
- `provider_with_base_url(api_key, model, base_url) -> Provider` — for compatible inference providers.
- `parse_response(String) -> Result(Message, AiError)` — pure JSON parsing, tested with golden files.
- `build_request_body(List(Message), List(ToolDefinition)) -> String` — pure, converts our message types to OpenAI's JSON schema.
- The returned `Provider` function:
  1. Builds the request body from messages + tool defs.
  2. Calls `pig/ai/http.post(base_url <> "/chat/completions", headers, body)`.
  3. Parses the response with `parse_response`.
  4. Returns `Result(Message, AiError)`.

**Helpful:** SPEC §3.1, §5.1; TESTING_STRATEGY §Part II Area: pig/ai ("Expect / Golden File Testing")

---

## Phase 4: Tool System

### Task 4.1 — `pig/tool` Types & Registry

**Test first:**
```
test/pig/tool/definition_test.gleam
```
- Test constructing a `ToolDefinition` with a handler function.
- Test that `to_json_schema(tool)` produces the correct JSON string for the LLM.
- Test registering tools into a registry (a `Dict(String, ToolDefinition)`).
- Test looking up a tool by name from the registry returns the correct tool.
- Test looking up a nonexistent tool returns `Error`.

**Implementation:**
```
src/pig/tool.gleam
src/pig/tool/definition.gleam (if split is preferred)
```
- `Tool` record: `Tool(definition: ToolDefinition, handler: fn(String) -> String)`.
  - `ToolDefinition` is reused from `pig/ai/tool_definition`.
  - Handler takes JSON arguments string, returns JSON result string.
- `ToolRegistry` type wrapping `Dict(String, Tool)`.
- `register(registry, tool)` / `lookup(registry, name)` / `list_definitions(registry)`.

**Helpful:** SPEC §3.4 (tool dispatch), §6.2 (parallelism), §7.1 (Custom Tools)

---

### Task 4.2 — `pig/tool` Execution (Pure)

**Test first:**
```
test/pig/tool/execution_test.gleam
test_data/tools/
```
- Test that `execute_tool(registry, tool_call)` returns the correct result string for a known tool.
- Test that `execute_tool` with an unknown tool name returns an error string (not a crash).
- Test that `execute_tool` with malformed JSON arguments returns an error string.
- All pure — no processes, no IO.

**Implementation:**
```
src/pig/tool/execution.gleam
```
- `execute_tool(ToolRegistry, ToolCall) -> String` — looks up the tool, calls the handler, returns result.
- Error handling for missing tools and bad arguments.

**Helpful:** SPEC §4 Step 3 (tool execution); TESTING_STRATEGY §Axiom 2 (ruthlessly pure)

---

## Phase 5: Agent Core (Pure State Machine)

### Task 5.1 — `pig/agent` State Type

**Test first:**
```
test/pig/agent/state_test.gleam
```
- Test constructing an initial `AgentState` from a config (provider, tools, system prompt).
- Test `add_message(state, message)` returns a new state with the message appended (immutability).
- Test `history(state)` returns messages in order.
- Test `set_active_tool_calls(state, calls)` stores them.

**Implementation:**
```
src/pig/agent/state.gleam
```
- `AgentState` record containing: `history: List(Message)`, `provider: Provider`, `tools: ToolRegistry`, `system_prompt: String`, `active_tool_calls: List(ToolCall)`, `config: AgentConfig`.
- Constructor and accessor/updater functions.

**Helpful:** SPEC §3.2 (agent state), §6.3 (state immutability)

---

### Task 5.2 — `pig/agent` Core Loop (Pure)

**This is the most critical module. It must be 100% testable without touching telemetry, network, or Tasks.**

**Test first:**
```
test/pig/agent/core_test.gleam
test_data/scenarios/01_simple_response.json
test_data/scenarios/02_single_tool_call.json
test_data/scenarios/03_multi_tool_call.json
test_data/scenarios/04_tool_then_response.json
```

Each scenario JSON fixture contains:
```json
{
  "initial_prompt": "What is 2+2?",
  "mock_responses": [
    { "type": "assistant_text", "content": "4" }
  ],
  "expected_final_message": { "role": "assistant", "content": "4" }
}
```

- **Scenario 1 (simple response):** Provider returns text → loop terminates, returns the text.
- **Scenario 2 (single tool call):** Provider returns one `ToolCall` → tool is executed → result appended → provider called again → returns text.
- **Scenario 3 (multi tool call):** Provider returns three `ToolCall`s → all executed → results appended → provider called again → returns text.
- **Scenario 4 (chained):** Tool call → response → another tool call → response → final text.

**The test harness (`check_agent_scenario`):**
```gleam
// test/support/harness.gleam
pub fn check_agent_scenario(scenario_path: String) -> Bool {
  let scenario = load_scenario(scenario_path)
  let state = initial_state(scenario)
    |> inject_mock_provider(scenario.mock_responses)
    |> inject_tools(scenario.tools)
  let result = pig/agent/core.step(state)
  assert_match(result, scenario.expected_final_message)
}
```

**Implementation:**
```
src/pig/agent/core.gleam
```
- `step(AgentState) -> StepResult`
- `StepResult` is a custom type:
  - `Complete(Message)` — final answer reached
  - `NeedsToolExecution(List(ToolCall), AgentState)` — tool calls need to be run
  - `Error(AiError)` — something went wrong
- `execute_tools_and_advance(AgentState, List(ToolCall)) -> AgentState` — pure tool execution, returns new state with `Tool` messages appended.
- The full loop: `run_to_completion(AgentState) -> Result(Message, AiError)` — recursive, calls `step` and `execute_tools_and_advance` until `Complete` or `Error`.

**Helpful:** SPEC §4 (Execution Loop Detail); TESTING_STRATEGY §Part II Area: pig/agent (Scenario-Driven Tests, pure state machine)

---

### Task 5.3 — `pig/agent` Telemetry Integration (in Core)

**Test first:**
```
test/pig/agent/telemetry_test.gleam
```
- Using the test listener from Task 2.2, run a simple scenario through the core loop.
- Assert that the captured events contain: `pig.inference.start`, `pig.inference.stop`, `pig.tool.start`, `pig.tool.stop` in the correct order.
- Assert metadata on events (model name, tool name, etc.).

**Implementation:**
```
src/pig/agent/core.gleam (modify)
```
- Add telemetry emit calls at the right points in `step` and `execute_tools_and_advance`.
- Import `pig/obs/events`.

**Helpful:** SPEC §3.4; TESTING_STRATEGY §Part II Area: pig/obs (Log Assertion Pattern)

---

## Phase 6: Agent OTP Actor

### Task 6.1 — `pig/agent` Actor Wrapper

**Test first:**
```
test/pig/agent/actor_test.gleam
```
- Test starting an agent actor with a mock provider.
- Test sending a `Run(prompt)` message and receiving a response.
- Test that the actor's state is isolated (two prompts don't bleed history).
- Test sending a `Stop` message terminates the actor.
- Test that a tool execution failure (handler crashes) does NOT crash the actor — it receives an `Error` result.

**Implementation:**
```
src/pig/agent.gleam
src/pig/agent/actor.gleam
```
- Use `gleam/otp/actor` to wrap the pure core.
- The actor holds `AgentState` and handles messages: `Run(String)`, `Stop`, `Interrupt`.
- On `Run`: appends `User` message, calls `core.run_to_completion`, sends back result.
- On `Stop`: stops the actor.
- The actor is intentionally thin — logic lives in `core.gleam`.

**Helpful:** SPEC §3.2 (OTP Actor), §6.1 (Supervision Trees), §4 Step 4 (Interruption); TESTING_STRATEGY §Axiom 1 (test features, not implementation)

---

### Task 6.2 — `pig/agent` Parallel Tool Execution

**Test first:**
```
test/pig/agent/parallel_tools_test.gleam
```
- Using the telemetry test listener, dispatch a scenario with 3 tool calls.
- Assert that all 3 `pig.tool.start` events are emitted BEFORE the first `pig.tool.stop` event.
- This proves parallelism without using `sleep()` or asserting on PIDs.

**Implementation:**
```
src/pig/agent/parallel.gleam (or modify actor.gleam)
```
- Use `gleam/otp/task` to spawn concurrent tasks for each tool call.
- Collect results (with a timeout).
- Wrap each task in error handling so a crash returns an `Error` string, not a process exit.

**Helpful:** SPEC §6.2 (Parallelism); TESTING_STRATEGY §Part II Area: pig/obs (proving parallelism via telemetry ordering)

---

## Phase 7: Skill System

### Task 7.1 — `pig/skill` Markdown Parsing

**Test first:**
```
test/pig/skill/load_test.gleam
test_data/skills/valid_skill/README.md
test_data/skills/valid_skill/examples/example.md
test_data/skills/missing_readme/other_file.md
test_data/skills/empty_skill/README.md
```
- Test `load("./test_data/skills/valid_skill")` returns `Ok(Skill)` with correct name, description (extracted from README), and file list.
- Test `load("./test_data/skills/missing_readme")` returns `Error`.
- Test `load("./test_data/skills/empty_skill")` returns `Ok` with empty description.

**Implementation:**
```
src/pig/skill.gleam
```
- `Skill` record: `Skill(name: String, description: String, path: String, files: List(String))`.
- `load(path: String) -> Result(Skill, SkillError)` — reads directory, parses `README.md` for name/description, lists supplementary files.
- `skill_to_system_fragment(Skill) -> String` — generates the text injected into the system prompt.

**Helpful:** SPEC §3.3 (Skill definition, discovery); TESTING_STRATEGY §Part II Area: pig/skill (Fixture-Driven)

---

### Task 7.2 — `pig/skill` Librarian Tool

**Test first:**
```
test/pig/skill/librarian_test.gleam
test_data/skills/gleam_expert/README.md
test_data/skills/gleam_expert/patterns/supervisor.md
```
- Test that `librarian_tool(skills)` produces a `Tool` with name `read_skill`.
- Test executing `read_skill` with `{"name": "gleam_expert"}` returns the skill's content.
- Test executing with an unknown skill name returns an error string.

**Implementation:**
```
src/pig/skill/librarian.gleam
```
- `librarian_tool(List(Skill)) -> Tool` — creates a tool that reads skill content on demand.
- The tool handler reads the skill's files from disk.

**Helpful:** SPEC §3.3 (Librarian Tool)

---

## Phase 8: Top-Level API

### Task 8.1 — `pig` Public API

**Test first:**
```
test/pig_test.gleam
```
- Test `pig.new(provider)` returns a `PigConfig` with defaults (empty tool registry, no system prompt, no persistence).
- Test `pig.with_skill(config, skill)` adds the skill and registers the librarian tool in the registry.
- Test `pig.with_tool(config, tool)` adds the tool to the registry.
- Test `pig.with_persistence(config, path)` sets the session directory.
- Test `pig.with_system_prompt(config, prompt)` sets the system prompt.
- Test `pig.with_model(config, model)` sets the model name.
- Test the full flow: `new → with_tool → start → run` using a mock provider returns the expected result.
- Test the full flow with `run_with_timeout`.

**Implementation:**
```
src/pig.gleam
```
- `PigConfig` (opaque) wraps `AgentConfig` + `skills` + `persistence_path`. Builder pattern:
  - `new(Provider) -> PigConfig` — wraps `agent/state.config(provider)` with defaults.
  - `with_tool(PigConfig, Tool) -> PigConfig` — registers tool in registry.
  - `with_skill(PigConfig, Skill) -> PigConfig` — adds skill + registers librarian tool.
  - `with_persistence(PigConfig, String) -> PigConfig` — sets session directory (for Phase 9).
  - `with_system_prompt(PigConfig, String) -> PigConfig` — sets system prompt.
  - `with_model(PigConfig, String) -> PigConfig` — sets model name.
- `Agent` (opaque) wraps `Subject(AgentMessage)` — the handle to a running agent.
- `start(PigConfig) -> Result(Agent, StartError)` — spawns the agent actor via `pig/agent/actor.start`.
- `run(Agent, String) -> Result(Message, AiError)` — 30s default timeout, delegates to `run_with_timeout`.
- `run_with_timeout(Agent, String, Int) -> Result(Message, AiError)` — sends prompt, waits for response.
- `stop(Agent) -> Nil` — stops the agent actor.
- `test_harness() -> PigConfig` — returns a config with a deterministic mock provider.

**Also modify:**
```
src/pig/agent/actor.gleam
```
- Add `supervised(config: AgentConfig, name: process.Name(AgentMessage)) -> ChildSpecification(Nil)`:
  - Creates a named actor (`actor.named(name)`) so the Subject can be recovered after supervisor start.
  - Returns `ChildSpecification(Nil)` — data is discarded per `static_supervisor` convention.
  - The start fn wraps `actor.start` and maps `Started(Subject)` to `Started(Nil)`.

**Supervisor architecture notes:**
- `gleam/otp/static_supervisor` stores `List(ChildSpecification(Nil))` — child data is discarded on add.
- To recover the agent's `Subject(AgentMessage)` after supervisor start, the actor must be named.
- `process.named_subject(name)` recovers the Subject from the registered name.
- `static_supervisor` has no stop API. Kill the supervisor pid to shut down — OTP cascades to children.
- Session writer (Phase 9) not built yet — supervisor only manages agent for now.

**Helpful:** SPEC §5 (Example Usage); TESTING_STRATEGY §Part III (Centralized `check` function)

---

### Task 8.2 — `pig` Supervision

**Test first:**
```
test/pig/supervisor_test.gleam
```
- Test `start_supervised(config)` returns `Ok(SupervisedAgent)`.
- Test `run(supervised, prompt)` returns the expected result through the supervised agent.
- Test `run_with_timeout(supervised, prompt, timeout)` works with explicit timeout.
- Test `stop(supervised)` terminates supervisor and agent — monitor on supervisor pid confirms `ProcessDown`.
- Test agent actor is still usable after `run` (not one-shot).

**Implementation:**
```
src/pig/supervisor.gleam
```
- `SupervisedAgent` record: `SupervisedAgent(agent: Agent, sup_pid: Pid)`.
- `start_supervised(PigConfig) -> Result(SupervisedAgent, StartError)`:
  1. Create unique name via `process.new_name()`.
  2. Build `ChildSpecification(Nil)` via `pig/agent/actor.supervised(config, name)`.
  3. Build `static_supervisor.new(OneForOne) |> add(spec) |> start`.
  4. Recover agent Subject: `process.named_subject(name)`.
  5. Return `SupervisedAgent(agent: Agent(subject), sup_pid: started.pid)`.
- `run(SupervisedAgent, String) -> Result(Message, AiError)` — 30s default, delegates to `run_with_timeout`.
- `run_with_timeout(SupervisedAgent, String, Int) -> Result(Message, AiError)` — delegates to `pig.run_with_timeout`.
- `stop(SupervisedAgent) -> Nil` — kills supervisor pid via `process.send_exit(sup_pid, shutdown)`. OTP cascades shutdown to agent child.
- Components can still be started standalone via `pig.start` for advanced users (no supervisor required).

**Helpful:** SPEC §6.1 (Supervision Trees)

---

## Phase 9: Session Persistence & Enriched Observability

Phase 9 redesigns the observability layer with two goals:
1. **Session persistence** — full-fidelity JSONL recording for conversation replay and debugging.
2. **OTel forward-compatibility** — ensure the data we capture can populate OpenTelemetry GenAI semantic conventions (spans with `gen_ai.*` attributes) without restructuring later.

**Key architectural decision:** Two first-class event channels, emitted from the same code paths:
1. **`SessionEvent`** — rich, typed events sent directly to registered pig consumers. Carries full message content, tool arguments/results, token counts, timing. All pig observability modules (session writer, terminal printer, future OTel exporter) read from `SessionEvent`s.
2. **`:telemetry`** — lightweight metrics emitted via `telemetry.execute/3`. The BEAM ecosystem standard — gives pig users zero-config integration with LiveDashboard, Telemetry.Metrics, `opentelemetry_telemetry`, AppSignal, etc. Carries durations, counts, model name — no message content.

Neither channel is a bridge or shim. Both are always emitted.

See "Event Distribution Architecture" below and Resolved Decisions #9–#10.

---

### Event Distribution Architecture

The agent emits two types of event for each significant action — a rich `SessionEvent` and a lightweight `:telemetry` event — from the same code paths.

**`SessionEvent` channel (pig consumers):**
```
pig/agent/core.gleam
  ↓ emits SessionEvent (fan-out to all registered consumers)
  ↓
  ├── pig/obs/session  (JSONL writer — full content)
  ├── pig/obs/terminal (pretty printer — lightweight fields)
  └── future pig/obs/otel (OTel GenAI semantics — full messages + spans)
```

**`:telemetry` channel (BEAM ecosystem):**
```
pig/obs/events.gleam
  ↓ emits [:pig, inference, :stop] etc. via telemetry.execute/3
  ↓
  └── ANY BEAM TELEMETRY CONSUMER (LiveDashboard, Telemetry.Metrics,
      opentelemetry_telemetry, AppSignal, custom handlers)
```

The agent never blocks on event delivery — all sends are fire-and-forget (`actor.send`, not `actor.call`).

**How SessionEvent consumers register:**
- The agent's `AgentConfig` holds a `List(Subject(SessionEvent))` of registered consumers.
- `pig.with_session_writer(config, path)` creates a session writer actor and registers its `Subject`.
- `pig.with_terminal_output(config)` creates a terminal printer actor and registers its `Subject`.
- On each event, the agent iterates the list and sends to each consumer. A crashed consumer is silently skipped (it's supervised separately).
- `:telemetry` events are always emitted — no registration needed (standard BEAM behavior).

---

### OTel GenAI Semantic Conventions Coverage

The enriched types (Phase 9 prerequisites) and `SessionEvent` ensure we capture everything needed for future `pig/obs/otel`. Since OTel needs full message bodies (`gen_ai.input.messages`, `gen_ai.output.messages`), the OTel exporter reads from `SessionEvent`s — the same canonical source as the session writer.

| OTel Attribute | Source | Available After |
|---------------|--------|----------------|
| `gen_ai.operation.name` | Hardcoded `"chat"` | Already |
| `gen_ai.provider.name` | `AgentConfig.provider_name` | Task 9.0d |
| `gen_ai.request.model` | `AgentConfig.model` | Already |
| `gen_ai.response.id` | `InferenceMetadata.response_id` → `SessionEvent` | Task 9.0a |
| `gen_ai.response.model` | `InferenceMetadata.response_model` → `SessionEvent` | Task 9.0a |
| `gen_ai.response.finish_reasons` | `InferenceMetadata.finish_reason` → `SessionEvent` | Task 9.0a |
| `gen_ai.usage.input_tokens` | `InferenceMetadata.input_tokens` → `SessionEvent` | Task 9.0a |
| `gen_ai.usage.output_tokens` | `InferenceMetadata.output_tokens` → `SessionEvent` | Task 9.0a |
| `gen_ai.input.messages` | `SessionEvent.InferenceCompleted.input_messages` | Task 9.1 |
| `gen_ai.output.messages` | `SessionEvent.InferenceCompleted.message` | Task 9.1 |
| `gen_ai.system_instructions` | `SessionEvent.SessionStarted.system_prompt` | Task 9.1 |
| `gen_ai.agent.id` | `AgentConfig.agent_id` → `SessionEvent` | Task 9.0d |
| `gen_ai.agent.name` | `AgentConfig.agent_name` → `SessionEvent` | Task 9.0d |
| `gen_ai.agent.description` | `AgentConfig.agent_description` → `SessionEvent` | Task 9.0d |
| `gen_ai.agent.version` | `AgentConfig.agent_version` → `SessionEvent` | Task 9.0d |
| `server.address` | Parse from `OpenAIConfig.base_url` | Already |
| `server.port` | Parse from `OpenAIConfig.base_url` | Already |
| `error.type` | `AiError` variant + detail → `SessionEvent.InferenceFailed` | Task 9.0a |

Deferred (not needed for v1 session persistence, add when building OTel exporter):
- `gen_ai.request.max_tokens`, `gen_ai.request.top_p`, `gen_ai.request.temperature` — request parameters not currently exposed.

---

### Task 9.0a — Enrich Provider Return Type (`InferenceResult`)

**Breaking change.** The `Provider` type alias currently returns `Result(Message, AiError)`. This drops critical metadata from provider responses (token counts, response IDs, finish reasons) that both session persistence and OTel need.

**Test first:**
```
test/pig/ai/provider_test.gleam (update)
test/pig/ai/inference_metadata_test.gleam (new)
```
- Test constructing `InferenceMetadata` with all optional fields.
- Test `InferenceMetadata.default()` returns all fields as `None`.
- Test that a provider function matching the new signature `fn(List(Message), List(ToolDefinition)) -> Result(InferenceResult, AiError)` compiles and returns correctly.
- Test `InferenceResult.message(result)` accessor.
- Test `InferenceResult.metadata(result)` accessor.

**Implementation:**
```
src/pig/ai/provider.gleam (modify)
```
- Define `InferenceMetadata` record:
  ```gleam
  pub type InferenceMetadata {
    InferenceMetadata(
      response_id: Option(String),      // "chatcmpl-9J3u..."
      response_model: Option(String),   // "gpt-4-0613" (may differ from request)
      finish_reason: Option(String),     // "stop", "tool_calls", "length"
      input_tokens: Option(Int),
      output_tokens: Option(Int),
    )
  }
  ```
- Define `InferenceResult` record:
  ```gleam
  pub type InferenceResult {
    InferenceResult(message: Message, metadata: InferenceMetadata)
  }
  ```
- Change `Provider` type alias:
  ```gleam
  pub type Provider = fn(List(Message), List(ToolDefinition)) -> Result(InferenceResult, AiError)
  ```
- Provide `InferenceMetadata.default() -> InferenceMetadata` (all `None`s) — convenience for constructing results where metadata isn't available.
- Provide `InferenceResult.from_message(Message) -> InferenceResult` — convenience constructor using default metadata.

**Impact:** All modules that call a `Provider` or construct one need updating:
- `pig/ai/openai.gleam` — Task 9.0b
- `pig/agent/core.gleam` — Task 9.0c
- `pig/agent/state.gleam` — no change (history still stores `Message`)
- All test files with mock providers — Task 9.0f

**Helpful:** OTel GenAI semantic conventions (`gen_ai.response.*`, `gen_ai.usage.*`)

---

### Task 9.0b — Update OpenAI Provider to Parse Response Metadata

**Test first:**
```
test/pig/ai/openai_test.gleam (update)
test_data/providers/openai_text_response.json (update with usage/id/model fields)
test_data/providers/openai_tool_call_response.json (update)
test_data/providers/openai_multi_tool_call_response.json (update)
```
- **Updated golden file tests:** Existing fixtures get enriched with top-level `id`, `model`, `usage` fields and per-choice `finish_reason`. Test that `parse_response` now returns `Ok(InferenceResult)` with correct metadata.
- Test `InferenceMetadata` fields are populated: `response_id`, `response_model`, `input_tokens`, `output_tokens`, `finish_reason`.
- Test that a response missing `usage` or `id` still parses (fields default to `None`).
- Test that the provider function returns `InferenceResult` (not bare `Message`).

**Implementation:**
```
src/pig/ai/openai.gleam (modify)
```
- Update `response_decoder()` to decode top-level `id` and `model` fields.
- Add `usage_decoder()` decoding `prompt_tokens` and `completion_tokens`.
- Decode `finish_reason` from each choice.
- `do_inference` wraps the parsed message + metadata into `InferenceResult`.
- `build_request_body` — no changes needed.

**Helpful:** OpenAI Chat Completions API response format

---

### Task 9.0c — Update Agent Core to Handle `InferenceResult`

**Test first:**
```
test/pig/agent/core_test.gleam (update)
test/pig/agent/telemetry_test.gleam (update)
```
- Update mock providers in test harness to return `InferenceResult` instead of bare `Message`.
- All existing scenario tests should still pass (verify `step` unwraps the message correctly).
- Test that `step` passes `InferenceMetadata` to telemetry events (token counts, response ID).

**Implementation:**
```
src/pig/agent/core.gleam (modify)
```
- `step()` calls `st.config.provider(msgs, defs)` which now returns `Result(InferenceResult, AiError)`.
- Unwrap `InferenceResult.message` for the `StepResult` branching logic (no change to `StepResult` type).
- Pass `InferenceResult.metadata` to `events.emit()` calls (enriched telemetry).
- `run_to_completion` return type unchanged — still `Result(Message, AiError)`.

**Helpful:** Existing core.gleam structure

---

### Task 9.0d — Add Agent Identity + Event Consumers to Config

**Test first:**
```
test/pig/agent/state_test.gleam (update)
test/pig_test.gleam (update)
```
- Test `config_with_agent_name(config, "Math Tutor")` sets the field.
- Test defaults: `agent_id`, `agent_name`, `agent_description`, `agent_version`, `provider_name` all default to `None`.
- Test `pig.with_agent_name(...)`, `pig.with_agent_id(...)` builder methods.
- Test `pig.with_provider_name(config, "ollama")` sets provider_name.
- Test `pig.with_session_writer(config, path)` creates a session writer and registers it as a consumer.
- Test `pig.with_terminal_output(config)` registers a terminal printer as a consumer.
- Test that registered consumers receive `SessionEvent`s when the agent runs.

**Implementation:**
```
src/pig/agent/state.gleam (modify)
src/pig.gleam (modify)
```
- Add to `AgentConfig`:
  ```gleam
  agent_id: Option(String),
  agent_name: Option(String),
  agent_description: Option(String),
  agent_version: Option(String),
  provider_name: Option(String),  // "openai", "ollama", etc.
  event_consumers: List(Subject(SessionEvent)),
  ```
- All default to `None` / `[]` in `config()` constructor.
- Add setter functions in `state.gleam` and builder methods in `pig.gleam`.
- `pig.with_session_writer(PigConfig, path) -> PigConfig` — creates session writer actor, registers `Subject`.
- `pig.with_terminal_output(PigConfig) -> PigConfig` — creates terminal printer actor, registers `Subject`.
- `state.add_event_consumer(config, consumer) -> AgentConfig` — adds a `Subject(SessionEvent)` to the list.

**Helpful:** OTel `gen_ai.agent.*` attributes; Phase 9 "Event Distribution Architecture"

---

### Task 9.0e — Enrich Telemetry Events with Response Metadata

**Test first:**
```
test/pig/obs/events_test.gleam (update)
test/pig/agent/telemetry_test.gleam (update)
```
- Test that `InferenceStop` now carries `input_tokens`, `output_tokens`, `response_id`, `finish_reason` fields.
- Test `InferenceException` carries `error_type` string.
- Test that captured telemetry events include the new metadata.

**Implementation:**
```
src/pig/obs/events.gleam (modify)
```
- Update `InferenceStop` variant:
  ```gleam
  InferenceStop(
    model: String,
    message_count: Int,
    duration_ms: Int,
    response_id: Option(String),
    finish_reason: Option(String),
    input_tokens: Option(Int),
    output_tokens: Option(Int),
  )
  ```
- Update `InferenceException` to carry `error_type: String`.
- Update `emit()` and `decode()` to handle new fields.
- Telemetry remains lightweight — no message content, just IDs and counts.

**Helpful:** OTel GenAI semantic conventions

---

### Task 9.0f — Update Existing Tests for Provider Type Change

**Test updates:**
```
test/pig/ai/message_test.gleam      — likely no change
test/pig/ai/error_test.gleam         — likely no change
test/pig/ai/tool_definition_test.gleam — likely no change
test/pig/ai/provider_test.gleam      — update for InferenceResult
test/pig/ai/openai_test.gleam        — update for InferenceResult
test/pig/ai/http_test.gleam          — likely no change
test/pig/tool/definition_test.gleam  — likely no change
test/pig/tool/execution_test.gleam   — likely no change
test/pig/agent/state_test.gleam      — update mock providers
test/pig/agent/core_test.gleam       — update mock providers
test/pig/agent/telemetry_test.gleam  — update for enriched events
test/pig/agent/actor_test.gleam      — update mock providers
test/pig/agent/parallel_tools_test.gleam — update mock providers
test/pig/skill/load_test.gleam       — likely no change
test/pig/skill/librarian_test.gleam  — likely no change
test/pig_test.gleam                  — update test_harness + mock providers
test/pig/supervisor_test.gleam       — update mock providers
test/support/harness.gleam           — update mock provider helpers
```

- Every mock provider currently returns `Ok(Assistant(...))`. Must now return `Ok(InferenceResult.from_message(Assistant(...)))`.
- Use `InferenceResult.from_message()` for mocks that don't care about metadata.
- Run full test suite and confirm all pass.

---

### Task 9.1 — `pig/obs/session` JSONL Session Writer

The session writer is an OTP actor that receives `SessionEvent`s as a registered consumer. It is the primary concrete implementation of the event consumer pattern — the model for how future consumers (OTel exporter, etc.) will work.

**Define `SessionEvent` type in a shared location** so it can be imported by `pig/agent/state.gleam` (for the consumer list type), `pig/obs/session.gleam`, `pig/obs/terminal.gleam`, and future consumers. Define it in `pig/obs/events.gleam` alongside the existing telemetry types.

**Test first:**
```
test/pig/obs/session_test.gleam
```
- **Pure serialization tests:**
  - Test `format_event(SessionStarted(...)) -> String` produces valid JSON (parseable).
  - Test `format_event(InferenceCompleted(...))` includes `message`, `input_messages`, `input_tokens`, `output_tokens`, `response_id`, `finish_reason`, `duration_ms`.
  - Test `format_event(ToolExecuted(...))` includes `tool_call` (with `arguments_json`), `result`, `duration_ms`.
  - Test `format_event(InferenceFailed(...))` includes error detail.
  - Test `format_event(SessionEnded(...))` includes reason.
  - Test that each `format_event` output is a single line (no embedded newlines).
- **Actor integration tests:**
  - Test `start(path)` returns `Ok(SessionWriter)`.
  - Test sending a `SessionEvent` to the writer, then reading the file and asserting line count and contents.
  - Test sending multiple events produces multiple JSONL lines in order.
  - Test `stop(SessionWriter)` terminates the actor cleanly.

**Implementation:**
```
src/pig/obs/session.gleam
```
- Define `SessionEvent` type:
  ```gleam
  pub type SessionEvent {
    SessionStarted(
      agent_id: Option(String),
      agent_name: Option(String),
      model: String,
      provider_name: Option(String),
      system_prompt: Option(String),
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
    ToolExecuted(
      tool_call: ToolCall,
      result: String,
      duration_ms: Int,
    )
    InferenceFailed(
      error: AiError,
      duration_ms: Int,
      input_messages: List(Message),
    )
    SessionEnded(reason: SessionEndReason)
  }

  pub type SessionEndReason {
    NormalEnd
    Error(AiError)
    MaxIterationsExceeded(Int)
    Interrupted
  }
  ```
- `SessionWriter` — opaque type wrapping `Subject(SessionEvent)`.
- `start(path: String) -> Result(SessionWriter, StartError)` — spawns the file-writing actor.
- `stop(SessionWriter) -> Nil` — sends stop message.
- `record(SessionWriter, SessionEvent) -> Nil` — sends event to writer (async, fire-and-forget).
- Pure serialization: `format_event(SessionEvent) -> String` — one JSON object per line.
  - Timestamp auto-populated from system clock inside `format_event`.
  - `Message` serialized with role, content, tool_calls (including `arguments_json`), thinking.
  - `ToolCall` serialized with id, name, arguments_json.

**Actor behavior:**
- Holds the file path as state.
- On each `SessionEvent`, appends `format_event(event) <> "\n"` to the file.
- On stop, closes gracefully.
- Async — never blocks the agent.

**JSONL format example:**
```jsonl
{"ts":"2025-01-15T10:30:00Z","event":"session_started","agent_name":"Math Tutor","model":"gpt-4","provider":"openai","system_prompt":"You are a helpful math tutor"}
{"ts":"2025-01-15T10:30:01Z","event":"inference_completed","message":{"role":"assistant","content":"","tool_calls":[{"id":"call_1","name":"calculator","arguments":"{\"expr\":\"2+2\"}"}]},"response_id":"chatcmpl-9J3u","response_model":"gpt-4-0613","finish_reason":"tool_calls","input_tokens":52,"output_tokens":15,"duration_ms":150,"input_messages":[{"role":"user","content":"What is 2+2?"}]}
{"ts":"2025-01-15T10:30:01Z","event":"tool_executed","tool_call":{"id":"call_1","name":"calculator","arguments":"{\"expr\":\"2+2\"}"},"result":"4","duration_ms":3}
{"ts":"2025-01-15T10:30:02Z","event":"inference_completed","message":{"role":"assistant","content":"2+2 equals 4!","tool_calls":[]},"response_id":"chatcmpl-9J3v","response_model":"gpt-4-0613","finish_reason":"stop","input_tokens":78,"output_tokens":8,"duration_ms":200}
{"ts":"2025-01-15T10:30:02Z","event":"session_ended","reason":"normal_end"}
```

**Helpful:** SPEC §3.4 (Session Store, JSONL); TESTING_STRATEGY §Axiom 5 (slow tests isolated); OTel GenAI semantic conventions

---

### Task 9.2 — `pig/obs/terminal` Pretty Printer

The terminal printer is a registered event consumer that receives `SessionEvent`s. It replaces the previous telemetry-handler-based design.

**Test first:**
```
test/pig/obs/terminal_test.gleam
```
- Test `format_event(SessionEvent) -> String` returns a human-readable string for each event variant.
- Test that `InferenceCompleted` events display token counts and finish reason when present.
- Test that `ToolExecuted` events show tool name, arguments summary, and duration.
- Test that `SessionStarted` shows agent name and model.
- Pure function — no actual terminal output.

**Implementation:**
```
src/pig/obs/terminal.gleam
```
- `start() -> Result(Subject(SessionEvent), StartError)` — spawns an actor that receives `SessionEvent`s and prints formatted output to stdout.
- `format_event(SessionEvent) -> String` — pure formatting for each variant.
- Shows token counts, durations, tool names, finish reasons — picks the lightweight fields.
- Registered as a consumer via `pig.with_terminal_output(config)`.

**Helpful:** SPEC §5.2 (terminal.attach())

---

## Phase 10: Integration Tests

### Task 10.1 — Integration Test Suite

**Tests:**
```
test/integration/openai_live_test.gleam
test/integration/openai_compatible_live_test.gleam
test/integration/full_agent_test.gleam
```
- These tests hit a real OpenAI-compatible API (requires `OPENAI_API_KEY`).
- Test a full agent with real inference, a simple tool, and skill loading.
- Also test with a custom `base_url` pointing to a local Ollama instance (if available).
- These are excluded from the default test run and require explicit opt-in (`mise run test-integration`).

**Configuration:**
```
mise.toml — add test-integration task
```

**Helpful:** TESTING_STRATEGY §Part III (Handling Slow/Impure Tests — explicit opt-in, no conditional skips)

---

## File Summary by Phase

| Phase | Source Files | Test Files | Test Data |
|-------|-------------|------------|-----------|
| 1 | `src/pig/ai/message.gleam`, `src/pig/ai/error.gleam`, `src/pig/ai/tool_definition.gleam`, `src/pig/ai/provider.gleam` | `test/pig/ai/message_test.gleam`, `test/pig/ai/error_test.gleam`, `test/pig/ai/tool_definition_test.gleam`, `test/pig/ai/provider_test.gleam` | — |
| 2 | `src/pig/obs/events.gleam` | `test/pig/obs/events_test.gleam`, `test/pig/obs/listener_test.gleam` | — |
| 3 | `src/pig/ai/http.gleam`, `src/pig/ai/openai.gleam` | `test/pig/ai/http_test.gleam`, `test/pig/ai/openai_test.gleam` | `test_data/providers/openai_*.json` |
| 4 | `src/pig/tool.gleam`, `src/pig/tool/execution.gleam` | `test/pig/tool/definition_test.gleam`, `test/pig/tool/execution_test.gleam` | `test_data/tools/*` |
| 5 | `src/pig/agent/state.gleam`, `src/pig/agent/core.gleam` | `test/pig/agent/state_test.gleam`, `test/pig/agent/core_test.gleam`, `test/pig/agent/telemetry_test.gleam`, `test/support/harness.gleam` | `test_data/scenarios/*.json` |
| 6 | `src/pig/agent.gleam`, `src/pig/agent/actor.gleam`, `src/pig/agent/parallel.gleam` | `test/pig/agent/actor_test.gleam`, `test/pig/agent/parallel_tools_test.gleam` | — |
| 7 | `src/pig/skill.gleam`, `src/pig/skill/librarian.gleam` | `test/pig/skill/load_test.gleam`, `test/pig/skill/librarian_test.gleam` | `test_data/skills/**/*` |
| 8 | `src/pig.gleam`, `src/pig/supervisor.gleam`, `src/pig/agent/actor.gleam` (add `supervised`) | `test/pig_test.gleam`, `test/pig/supervisor_test.gleam` | — |
| 9 | `src/pig/ai/provider.gleam` (modify), `src/pig/ai/openai.gleam` (modify), `src/pig/agent/core.gleam` (modify), `src/pig/agent/state.gleam` (modify), `src/pig/obs/events.gleam` (modify), `src/pig/obs/session.gleam`, `src/pig/obs/terminal.gleam`, `src/pig.gleam` (modify) | `test/pig/ai/inference_metadata_test.gleam`, `test/pig/obs/session_test.gleam`, `test/pig/obs/terminal_test.gleam`, + updates to ~10 existing test files | — |
| 10 | — | `test/integration/*.gleam` | — |

---

## Resolved Decisions

1. **HTTP:** Use `gleam_http` + `gleam_httpc` with a thin wrapper (`pig/ai/http.gleam`). The `logging` package is for internal logging only.
2. **Streaming:** Deferred to a later phase. Provider interface is request/response only for v1.
3. **Middleware:** Deferred until we have a working base.
4. **Session Stores:** JSONL file only for now.
5. **Supervisor:** Export `pig.start_supervised(config)` as the easy path. All components also startable standalone.
6. **Target:** Erlang only. `target = "erlang"` in `gleam.toml`.
7. **Provider Return Type:** `Provider` returns `Result(InferenceResult, AiError)` — not bare `Result(Message, AiError)`. `InferenceResult` carries the `Message` plus `InferenceMetadata` (response ID, token counts, finish reason, response model). This ensures session persistence and OTel have access to provider response metadata without re-parsing.
8. **Agent Identity:** `AgentConfig` carries optional `agent_id`, `agent_name`, `agent_description`, `agent_version`, and `provider_name`. These populate OTel `gen_ai.agent.*` attributes and session headers. All default to `None` — opt-in.
9. **Two First-Class Event Channels:** pig emits two independent event channels from the same code paths. (1) `SessionEvent` — rich typed events sent directly to registered pig consumers (session writer, terminal printer, OTel exporter). Carries full message content. (2) `:telemetry` — lightweight metrics emitted via `telemetry.execute/3`. The BEAM ecosystem standard — zero-config integration with LiveDashboard, Telemetry.Metrics, `opentelemetry_telemetry`, AppSignal. Neither is a bridge or shim.
10. **SessionEvent is canonical for pig consumers.** ALL pig observability modules (session writer, terminal, future OTel) read from `SessionEvent`s. `:telemetry` serves the broader BEAM ecosystem — it is a first-class channel for a different audience.
