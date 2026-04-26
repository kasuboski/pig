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

**Observability Model — Logging vs Telemetry:**

These are two separate channels serving two different audiences:

| | `:telemetry` (`pig/obs`) | `:logger` (`logging`) |
|---|---|---|
| **Audience** | Library users & tooling (JSONL, OTel, dashboards) | Library developers (us, debugging `pig` internals) |
| **Content** | Structured events with typed measurements + metadata | Freeform debug text |
| **Examples** | `[:pig, :inference, :stop]` with `%{duration_ms: 150}` | `[debug] pig/ai/http: POST /v1/chat/completions -> 429, retrying` |
| **Consumers** | `pig/obs/terminal`, `pig/obs/session`, future `pig/obs/otel` | Console, dev-time log files |
| **Visibility** | User-facing, always-on when handlers are attached | Off by default, enabled via log level configuration |

**Golden rule: Never duplicate information across both channels.**
- If telemetry covers it (inference start/stop, tool execution), don't also log it.
- `:logger` (via the `logging` package) is for the gaps: HTTP transport debugging, configuration validation warnings, internal state that isn't a user-facing "event."
- `pig/obs/terminal` is NOT a logger — it's a telemetry handler that formats events for human reading.

**Build Order Rationale:**
```
pig/ai types ──► pig/obs events ──► pig/ai http ──► pig/ai/openai ──► pig/tool ──► pig/agent (pure) ──► pig/agent (actor) ──► pig/skill ──► pig (top-level + supervisor) ──► pig/obs persistence
```

Types come first (everything depends on `Message` and `AiError`). Telemetry event definitions come next so every subsequent layer can emit events as it's built — observability is not bolted on later. The HTTP wrapper goes before the provider so it has something to build on. The pure agent loop is tested before the OTP wrapper. Skills come after tools since the "librarian" is itself a tool.

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
- Test `pig.new(provider)` returns an `AgentConfig` with defaults.
- Test `pig.with_skill(config, skill)` adds the skill and registers the librarian tool.
- Test `pig.with_tool(config, tool)` adds the tool to the registry.
- Test `pig.with_persistence(config, path)` sets the session directory.
- Test the full flow: `new → with_skill → with_tool → start → run` using a mock provider returns the expected result.

**Implementation:**
```
src/pig.gleam
```
- `AgentConfig` builder: `new(Provider)`, `with_skill(Skill)`, `with_tool(Tool)`, `with_persistence(String)`.
- `start(AgentConfig) -> Result(Actor, StartError)` — spawns the agent actor.
- `run(Actor, String) -> Result(Message, AgentError)` — sends a prompt and waits for the result.
- `test_harness()` — a helper that returns a config with a deterministic mock provider (for external test suites using `pig`).

**Helpful:** SPEC §5 (Example Usage); TESTING_STRATEGY §Part III (Centralized `check` function)

---

### Task 8.2 — `pig` Supervision

**Test first:**
```
test/pig/supervisor_test.gleam
```
- Test `pig.start_supervised(config)` returns `Ok` with a running supervisor and a usable agent.
- Test that the supervisor's child processes (session writer, agent) are running.
- Test that `pig.run` works through the supervised agent.
- Test that stopping the supervisor cleans up all child processes.

**Implementation:**
```
src/pig/supervisor.gleam
```
- `start_supervised(AgentConfig) -> Result(SupervisedAgent, StartError)` — starts a `gleam/otp/supervisor` with the session writer and agent as children.
- `SupervisedAgent` wraps the agent actor and supervisor reference.
- `stop(SupervisedAgent) -> Nil` — graceful shutdown.
- Components can still be started standalone for advanced users (no supervisor required).

**Helpful:** SPEC §6.1 (Supervision Trees)

---

## Phase 9: Session Persistence

### Task 9.1 — `pig/obs` JSONL Session Writer

**Test first:**
```
test/pig/obs/session_test.gleam
```
- Test `session_entry(event, metadata, timestamp) -> String` produces valid JSONL (one JSON object per line).
- Test that the JSONL contains the expected fields: event name, timestamp, metadata.
- Test with a real file: attach the session writer, emit some events, read the file, assert line count and contents.

**Implementation:**
```
src/pig/obs/session.gleam
```
- `SessionWriter` — an OTP actor that listens to telemetry events and appends JSONL lines to a file.
- `start(path: String) -> Result(SessionWriter, StartError)`
- `stop(SessionWriter) -> Nil`
- Pure serialization function: `format_entry(event, meta, ts) -> String`.

**Helpful:** SPEC §3.4 (Session Store, JSONL); TESTING_STRATEGY §Axiom 5 (slow tests isolated)

---

### Task 9.2 — `pig/obs/terminal` Pretty Printer

**Test first:**
```
test/pig/obs/terminal_test.gleam
```
- Test `format_event(event, metadata) -> String` returns a human-readable string for each event type.
- Pure function — no actual terminal output.

**Implementation:**
```
src/pig/obs/terminal.gleam
```
- `attach()` — attaches a telemetry handler that prints formatted events to stdout.
- `format_event/2` — pure formatting.

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
| 8 | `src/pig.gleam`, `src/pig/supervisor.gleam` | `test/pig_test.gleam`, `test/pig/supervisor_test.gleam` | — |
| 9 | `src/pig/obs/session.gleam`, `src/pig/obs/terminal.gleam` | `test/pig/obs/session_test.gleam`, `test/pig/obs/terminal_test.gleam` | — |
| 10 | — | `test/integration/*.gleam` | — |

---

## Resolved Decisions

1. **HTTP:** Use `gleam_http` + `gleam_httpc` with a thin wrapper (`pig/ai/http.gleam`). The `logging` package is for internal logging only.
2. **Streaming:** Deferred to a later phase. Provider interface is request/response only for v1.
3. **Middleware:** Deferred until we have a working base.
4. **Session Stores:** JSONL file only for now.
5. **Supervisor:** Export `pig.start_supervised(config)` as the easy path. All components also startable standalone.
6. **Target:** Erlang only. `target = "erlang"` in `gleam.toml`.
