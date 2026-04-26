


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

---

## 🏗️ Part II: Area-Specific Guidelines

### `pig/agent` (The Execution Loop)
**Goal:** Verify state transitions, tool dispatching, and loop termination.
*   **Strategy: Scenario-Driven Tests.** 
*   Do not spin up the actual Agent OTP process for logical tests. Test the pure state machine (e.g., `pig/agent/core.next_step(state, message)`).
*   Use externalized JSON files in `./test_data/scenarios/`. A scenario file should contain:
    *   Initial Agent State/Prompt.
    *   A list of deterministic `mock_responses` (simulating an LLM).
    *   The `expected_final_message`.
*   **Rule:** The core execution loop must be 100% testable without touching `:telemetry`, network, or concurrent `Tasks`.

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

---

## 🛠️ Part III: Practical Patterns

### 1. The Centralized `check` Function
When writing tests for the agent, use a unified test harness function. 

```gleam
// test/support/harness.gleam
pub fn check_agent_scenario(scenario_path: String) {
  // 1. Load data
  let scenario = load_scenario(scenario_path)
  
  // 2. Setup pure state
  let state = pig.test_harness()
    |> pig.feed_history(scenario.history)
    |> pig.inject_deterministic_provider(scenario.mock_responses)
  
  // 3. Execute pure computation
  let result = pig.execute_logic(state)
  
  // 4. Assert
  assert_match(result, scenario.expected_output)
}
```

### 2. Handling Slow/Impure Tests
Integration tests (hitting the real Anthropic API or orchestrating real filesystem operations) belong in `test/integration/`. 

*   **Do NOT** use inline conditionals to bypass them (e.g., `if missing_api_key { return pass }`). This leads to a false sense of security.
*   **DO** use your test runner's configuration to exclude the `integration/` directory by default, requiring an explicit opt-in (e.g., `mise run test-integration` or CI configurations) to run the slow tests.

### 3. Embrace "Value In, Value Out"
If you find yourself writing a test that requires starting a process, sending it a message, waiting for a reply, and checking a mock... **stop**. 
Refactor the module so that the logic making the decision is a pure function taking a Record and returning a Record. Test that pure function. The process wrapping it should be so thin it barely needs testing.
