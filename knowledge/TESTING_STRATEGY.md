# `pig` Testing Guide: Purity, Extent, and Resilience

This guide outlines the testing philosophy and concrete strategies for the `pig` project. It is designed to be read by human developers and AI agents alike to ensure a unified approach to quality and maintainability.

Our testing strategy is built on two core dimensions: **Purity** (minimizing IO) and **Extent** (exercising the natural boundaries of a feature).

---

## 🏛️ Part I: High-Level Axioms

These axioms govern every test written in the `pig` codebase. If a test violates these principles, it should be refactored.

### 1. The "Neural Network" Test (Feature over Implementation)
Tests must verify **features, not internal code**. If we entirely replace the OTP `gen_server`/`Actor` powering the agent with a completely different mechanism, **no tests should break**. We test the contract (Input -> State -> Action), not the internal function signatures.

### 2. Ruthlessly Optimize Purity (Value In, Value Out)
IO (network calls, disk reads, process spawning) makes tests slow, flaky, and hard to debug. Push IO to the absolute edge of the system. The core logic of the agent must be a **pure function** that can be tested in microseconds.

### 3. Embody the `check` Idiom (Anti-Ossification)
Do not let test files call public library setup functions (`pig.new()`, `agent.run()`, etc.) directly in every test case. Instead, define a single, centralized `check_xyz` function per domain.
*   **Why?** If our API boundary changes, we update *one* `check` function, instantly fixing hundreds of data-driven tests.

### 4. Data-Driven and Externalized
Wherever possible, define test inputs and expected outputs as data (JSON, YAML, or Markdown fixtures) outside the test code (`./test_data/`). This forces purity, enables automated case generation, and allows alternative implementations to share the same test suite.

### 5. Explicit "Slow" Boundaries
Do not mock the network to speed up tests; instead, test the pure core. When we *must* test the network or real disk IO (the "Ladder of Impurity"), these tests must be isolated into a specific integration suite.

### 6. Don't Test Gleam Language Features
Do not write tests that merely verify Gleam constructor behavior — e.g., constructing a record and asserting the field values are what you just set. Test **logic**, not data movement. If a type has no behavior beyond construction, it needs no tests.

---

## 🏗️ Part II: Sans-IO Testing Patterns

The sans-IO architecture gives us a clean split for testing:

### Pure Core Tests (`update_test`, `update_scenario_test`)
The pure core (`update.gleam`) has the signature `update(state, msg) -> StepResult(msg)`. It's a pure function — same inputs always produce same outputs. No IO, no mocks, no processes.

**What to test:**
- State transitions: given state + message, does the core return the right StepResult?
- Effect generation: does the core produce `CallProvider` for text prompts, `ExecuteTools` for tool calls?
- Iteration counting: does the core track iterations correctly?
- Circuit breaker: does the core return `Failed` when max iterations exceeded?
- History accumulation: does the core correctly append messages to history?

**What NOT to test:**
- Don't test the `Effect` or `StepResult` constructors themselves.
- Don't test that `AgentMsg` variants exist.
- Don't test state construction (setting fields on `AgentState`).

```gleam
// Good: testing state machine logic
pub fn provider_error_increments_iterations_test() {
  let state = make_state([])
  let result = update(state, ProviderResponded(Error(RateLimited)))
  let assert Failed(_, _) = result
}

// Good: assert the effect's behavior, not its constructor fields
pub fn prompt_produces_provider_effect_test() {
  let assert Continue(_, [CallProvider(messages:, tools:, on_response: _)]) =
    update(make_state([]), UserPrompt("hello"))
  should.equal(messages, [User("hello")])
  should.equal(tools, [])
}
```

`CallProvider` intentionally contains only messages, tools, and `on_response`.
The runtime owns inference settings and constructs the one-argument
`InferenceRequest`; test those settings at the runtime/provider boundary.

### Hook Composition Tests (`hooks_test`)
Hooks are *functions* — `fn(Event) -> Action` — but they may be impure at runtime (querying databases, calling guardrail LLMs, fetching policy from remote services). The *composition functions* (`decide_tool_call`, `decide_tool_result`, `decide_messages`) are pure: they take a list of hooks and an event, run handlers in order, and return a decision.

**What to test:**
- Decision logic: first Block wins, transformers chain
- Attribution: `ToolBlocked(hook_name:, reason:)` carries the right name and reason
- Fire-and-forget: all handlers run even if one returns something

**How to test:** Use inline test hooks (pure closures) that return fixed actions. This tests the composition semantics — the wiring — without exercising impure hook behavior. Impure hooks are tested through the runtime with real IO or stubs.

### Runtime Tests (`runtime_test`)
The runtime interpreter (`runtime.gleam`) does IO — provider calls, tool execution, event emission, hook application. These tests use a stub provider and real OTP processes.

**What to test:**
- Effect execution: does the runtime call the provider for `CallProvider` effects?
- Hook wiring: do hooks run as middleware on effects?
- Event emission: does the runtime emit the right `SessionEvent` values?
- Parallel tool execution: are tools spawned concurrently?
- Resilience: does the runtime handle provider errors gracefully?
- History accumulation: does the runtime feed results back correctly?

---

## 🏗️ Part III: Area-Specific Guidelines

### `pig/agent` (The Execution Loop)
**Goal:** Verify state transitions, tool dispatching, and loop termination.
*   **Strategy: Scenario-Driven Tests.**
*   Do not spin up the actual runtime OTP process for logical tests. Test the pure state machine (`update.gleam`) directly.
*   Use the test harness (`test/support/harness.gleam`) to construct `AgentState` values without IO.
*   **Rule:** The pure core execution loop must be 100% testable without touching `:telemetry`, network, or concurrent `Tasks`.

### `pig/ai` (Provider Normalization)
**Goal:** Ensure OpenAI, Anthropic, and Local models map perfectly to our unified `Message` type.
*   **Strategy: Expect / Golden File Testing.**
*   Do not mock HTTP clients.
*   **Input:** Raw JSON strings captured directly from the provider APIs (e.g., `./test_data/providers/anthropic_tool_call_raw.json`).
*   **Assertion:** Pass the raw JSON into the parser and assert against a known, hardcoded `pig/ai.Message` Gleam record. If a provider changes their schema, we update the parser and regenerate the golden file.

### `pig/skill` & `pig/tool` (The Knowledge and Hands)
**Goal:** Verify markdown parsing, skill discovery, and tool schema generation.
*   **Strategy: Fixture-Driven Boundary Tests.**
*   Maintain a `./test_data/skills/` directory with real, valid, and invalid markdown files and directories.
*   Test that `skill.load()` produces the correct internal Data structures based strictly on those physical files.

### `pig/obs` (Observability & Concurrency)
**Goal:** Ensure the system runs tools in parallel and emits correct traces.
*   **Strategy: The Log Assertion Pattern.**
*   **Do not use `sleep()` or timeout hacks** to test concurrency. Do not assert on process IDs (PIDs).
*   Instead, attach a test listener to the `:telemetry` events.
*   To prove parallelism: Dispatch 3 slow tools. Assert that the `pig.tool.start` telemetry event for all 3 tools is recorded *before* the first `pig.tool.stop` event.

### `pig/hooks` (Lifecycle Mediation)
**Goal:** Verify hook composition semantics — blocking, transformation, and fire-and-forget.
*   **Strategy: Pure Composition Tests + Runtime Integration Tests.**
*   The *composition functions* (`decide_tool_call`, etc.) are pure and testable with value-in, value-out using inline closures.
*   Individual hooks *may be impure* (database queries, API calls). Impure hooks are tested through the runtime with stubs or real IO.
*   No OTP processes needed for composition tests.
*   Test decision types carry attribution (hook names, reasons, transformer lists).

---

## 🛠️ Part IV: Practical Patterns

### 1. The Centralized `check` Function
When writing tests for the agent, use a unified test harness function.

```gleam
// test/support/harness.gleam
pub fn check_update(state: AgentState, msg: AgentMsg) -> StepResult(AgentMsg) {
  update.update(state, msg)
}
```

For multi-step scenarios:

```gleam
// test/support/harness.gleam
pub fn check_scenario(steps: List(AgentMsg)) -> AgentState {
  list.fold(steps, fresh_state(), fn(state, msg) {
    case update.update(state, msg) {
      Done(state, _) -> state
      Continue(state, _) -> state
      Failed(state, _) -> state
    }
  })
}
```

### 2. Handling Slow/Impure Tests
Integration tests (hitting a real API or orchestrating real filesystem operations) belong in `test/integration/`.

*   **Env var gating is allowed for integration tests.** Each integration test file may check for an environment variable (e.g., `PIG_RUN_INTEGRATION=1`) and skip all tests if it is not set. This is the approved way to keep `gleam test` green without a false sense of security — the skip is explicit and visible.
*   **Do NOT** use env var gating in unit tests. Unit tests must always run.
*   **DO** set the gating variable in `mise run test-integration` so the opt-in path is one command.
*   Integration tests must NOT be a separate compile target. They live in `test/integration/` alongside other test code, compiled as part of the normal `gleam test` build.

### 3. Embrace "Value In, Value Out"
If you find yourself writing a test that requires starting a process, sending it a message, waiting for a reply, and checking a mock... **stop**.
Refactor the module so that the logic making the decision is a pure function taking a Record and returning a Record. Test that pure function. The process wrapping it should be so thin it barely needs testing.

### 4. Test the Two Layers Separately
The sans-IO architecture means you test two layers with different strategies:

| Layer | Module | Test style | IO needed? |
|-------|--------|-----------|------------|
| Pure core | `update.gleam` | `(state, msg) → StepResult` assertions | No |
| Runtime | `runtime.gleam` | Stub provider + process + event capture | Yes (OTP) |

Never mix the two. If you're starting a process to test core logic, you've gone wrong.
