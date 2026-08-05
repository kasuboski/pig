# Sans-IO Architecture

## Overview

Pig's agent loop is structured as a **sans-IO state machine** inspired by Lustre and Elm's architecture. The core produces pure data — state transitions and effect requests — while a separate runtime interprets those effects, applies hooks, and executes against the real world (HTTP, processes, files).

The separation is total. The core has no imports for HTTP clients, process spawning, file I/O, or telemetry. It is a pure function from `(state, msg)` to `(state, effects)`. All IO — including hooks — belongs to the runtime.

---

## Philosophy

### Effects are declarations of intent, not actions

The core never *does* anything. It describes what it *wants done*. LLM inference, tool execution, and any other interaction with the outside world are represented as values — effect requests that a runtime must interpret. This is the same insight that drives Elm's `Cmd`, Lustre's effect system, and the broader sans-IO pattern in Python HTTP frameworks.

Effects are emitted before hooks run. The core says "execute these tools." The runtime's hooks may block some, approve others, or transform messages before the LLM call. The effect is the *intent*; the audit trail records what *actually happened*. These are different things, and keeping them separate is more honest.

### Hooks are IO — and the runtime owns all IO

Hooks may be impure. An `on_tool_call` hook might query a database to check permissions, call a guardrail LLM to evaluate risk, or fetch policy from a remote service. An `on_before_inference` hook might retrieve context from a vector database to inject into messages. An `on_tool_result` hook might call a PII redaction API.

Because hooks can do IO, they cannot live in the core without breaking its purity. Hooks are middleware that the runtime applies to effects between the core's declaration and the runtime's execution. The core remains pure. The runtime provides the execution environment for hooks.

### Observability is a consequence, not a feature

Audit trails, session logs, and telemetry are produced by the runtime as it executes effects and applies hooks. The core doesn't know about dispatchers, JSONL files, or telemetry. The runtime is the single producer of all `SessionEvent` values — it generates them from its own activities (hook processing and effect execution).

### Policy in hooks, mechanism in the runtime

Hooks express *policy* — "block this tool," "transform these messages," "this tool requires approval." The runtime provides *mechanism* — HTTP clients, process pools, approval UIs, rate limiters, database lookups. The same state machine can run behind a CLI, a web server, or a test harness without modification.

---

## Architecture Diagram

```text
┌─────────────────────────────────────────────────────────┐
│                        CORE (pure)                      │
│                                                         │
│   update(state, msg) → (state, List(Effect(msg)))       │
│                                                         │
│   Produces state and effect requests.                   │
│   Zero IO. Zero hook logic. Zero telemetry.             │
│   Zero knowledge of hooks.                              │
└──────────────────────────┬──────────────────────────────┘
                           │
                    List(Effect(msg))
                           │
┌──────────────────────────▼──────────────────────────────┐
│                     RUNTIME (impure)                    │
│                                                         │
│   For each effect:                                      │
│     1. Apply hooks as middleware (may do IO)            │
│     2. Execute the (possibly modified) effect           │
│     3. Produce SessionEvents from hooks + execution     │
│                                                         │
│   Manages HITL approval flows, concurrency, retries.    │
│   Fires notification hooks at lifecycle points.         │
│   Emits: unified SessionEvent stream                    │
└──────────────────────────┬──────────────────────────────┘
                           │
                    List(SessionEvent)
                           │
┌──────────────────────────▼──────────────────────────────┐
│               DISPATCHER + CONSUMERS                    │
│                                                         │
│   Dispatcher fans out SessionEvents to:                 │
│   - Terminal printer                                    │
│   - JSONL session writer                                │
│   - BEAM :telemetry                                     │
│   - Any registered consumer                             │
└─────────────────────────────────────────────────────────┘
```

---

## Core Components

### Messages

Messages drive the state machine. They represent both user inputs and runtime responses:

- **UserPrompt** — a new prompt to process
- **ProviderResponded** — the LLM's response (or an error), delivered by the runtime after executing a `CallProvider` effect
- **ToolResults** — tool execution outcomes, delivered by the runtime after executing an `ExecuteTools` effect

The runtime constructs response messages from effect execution and feeds them back into `update`. This closes the loop. The core doesn't know or care whether a tool was blocked by a hook, approved by a human, or executed by a machine — it just sees `ToolResults`.

### StepResult

`StepResult` is the outcome of a single state transition — what happened after processing a message. It carries:

- **State** — the new agent state (history, iterations, config)
- **Effects** — requests for the runtime to execute (may be empty if the loop is done)

There are three variants:

- **Done** — the agent produced a final answer. No further effects.
- **Continue** — the agent needs more work (inference, tool execution). Contains effects.
- **Failed** — an unrecoverable error occurred.

The core does not produce observations. The core does not know about hooks. The core's job is purely: given this state and this message, what is the next state and what effects do I need? In the implementation, this is `pig/agent/update.update(state, msg) -> StepResult(msg)`.

### Effects

Effects are the core's requests to the runtime. There are exactly two:

**CallProvider** — "send these messages and tool definitions to the LLM, give me the response."

The core emits this with the messages it *thinks* should be sent (assembled from history + system prompt). The runtime's `on_before_inference` hooks may transform messages before it builds the one-argument `InferenceRequest` from those messages, the tools, and the runtime's current agent settings. The core does not own the settings or perform the call. An explicit thinking `Off` is distinct from an unset setting, which delegates to the provider default.

**ExecuteTools** — "execute these tool calls, give me all the results."

The core emits all tool calls the LLM requested. The runtime's `on_tool_call` hooks decide which to allow, block, or flag for human approval. Blocked tools come back as error results. Approved tools execute normally. The core sees a uniform `ToolResults` message either way.

Two effects. No more, no less. Every runtime must handle exactly these two branches. Simplicity in the type leads to simplicity in the interpreters.

---

## Hooks

### All hooks run in the runtime

There is no split between "core hooks" and "runtime hooks." All hooks run in the runtime because any hook may be impure. The runtime applies hooks as middleware on effects, between the core's declaration and the runtime's execution.

### Hook types and when they fire

**Transform hooks** (modify data flowing through the pipeline):

| Hook | What it can do | Where the runtime applies it |
|---|---|---|
| `on_before_inference` | Transform messages before the LLM call. May fetch context from a vector DB, inject dynamic system prompts, redact sensitive content. | Before executing `CallProvider` |
| `on_tool_result` | Transform tool results before they become `ToolResults` messages. May redact PII via an external API, truncate output, enrich with metadata. | After executing `ExecuteTools`, before constructing `ToolResults` |

**Decision hooks** (change which effects get executed):

| Hook | What it can do | Where the runtime applies it |
|---|---|---|
| `on_tool_call` | Allow, block, or flag a tool for human approval. May query a permissions database, call a guardrail LLM, check a policy service. | Before executing individual tools within `ExecuteTools` |

**Notification hooks** (pure observation, no data change):

| Hook | What it can do | Where the runtime fires it |
|---|---|---|
| `on_after_inference` | React to a completed inference. May log, update metrics, trigger side effects. | After `CallProvider` execution completes |
| `on_error` | React to an error. May alert, retry, fall back. | After any error during effect execution |
| `on_complete` | React to loop completion. May finalize state, write summaries. | When the core returns `Done` |
| `on_session_start` | React to session beginning. | Process lifecycle (actor init) |
| `on_session_shutdown` | React to session ending. | Process lifecycle (actor terminate) |

### Human-in-the-loop as a hook decision

The `on_tool_call` hook can return three things:

- **AllowTool** — execute normally
- **BlockTool(reason)** — don't execute, return an error result to the LLM
- **RequireApproval** — flag the tool for human approval before execution

The runtime reads this decision and implements the approval mechanism. A CLI runtime prompts on stdin. A web runtime sends a WebSocket message and waits. A test runtime auto-approves. The core sees `ToolResults` regardless — it doesn't know whether a human was involved.

This means HITL is *configurable policy* (the hook decides what needs approval) with *pluggable mechanism* (the runtime decides how to ask). Neither the core nor the effect types change.

### Impure hooks and their implications

Because hooks can do IO, the runtime must handle hook failures gracefully. If an `on_tool_call` hook queries a database and the database is down, the runtime decides the fallback — treat as blocked, treat as allowed, or propagate the error. This is a runtime concern, not a core concern.

Impure hooks also mean that replay is not simply re-running the core's `update` function with recorded messages. A replay recording must capture both:

- The `(msg, state)` inputs to `update` — for verifying deterministic state transitions
- The hook decisions made by the runtime — for reproducing the full execution path

Replay re-runs `update` to verify state, but replays recorded hook decisions rather than re-executing potentially impure hooks. This is analogous to replaying a recorded game: you verify the board state at each move, but you replay the recorded random events rather than regenerating them.

---

## The Runtime

### Responsibilities

The runtime is the interpreter. It:

1. Calls `update.update(state, msg)` to get the next state and effects
2. For each effect, applies hooks as middleware (may do IO)
3. Executes the (possibly modified) effects against the real world
4. Produces `SessionEvent` values from hook processing and effect execution
5. Emits all `SessionEvent` values to the dispatcher in order
6. Feeds effect results back into the loop as new messages
7. Fires notification hooks at appropriate lifecycle points

### The effect pipeline

For each `CallProvider` effect:

1. Run `on_before_inference` hooks — may transform messages (may do IO)
2. Build `InferenceRequest` with the transformed messages, tools, and current runtime-owned settings
3. Call the LLM with that request
4. Fire `on_after_inference` notification hooks
5. Produce `InferenceStarted` and `InferenceCompleted` (or `InferenceFailed`) session events
6. Emit the inference stop event and feed `ProviderResponded` back to the core as a new `AgentMsg`

For each `ExecuteTools` effect:

1. Run `on_tool_call` for each tool call — allow, block, or require approval (may do IO)
2. Blocked tools get error results inline (no execution)
3. Tools requiring approval go through the HITL flow (suspend until human responds)
4. Allowed tools execute (may do IO)
5. Run `on_tool_result` hooks on each result — may transform (may do IO)
6. Produce `ToolStarted`, `ToolExecuted`, `ToolBlocked` session events
7. Feed `ToolResults` back to the core

The core sees `ProviderResponded` and `ToolResults` — it never sees the hook pipeline.

### The unified event stream

The runtime produces a single stream of `SessionEvent` values from its own activities:

**From hook processing** — when hooks transform messages or block tools, the runtime knows because it ran the hooks. It produces `ToolBlocked`, `HookActed`, and similar events.

**From effect execution** — the runtime produces `InferenceStarted`, `InferenceCompleted`, `ToolStarted`, `ToolExecuted`, etc. These carry timing, token counts, and response metadata that only the runtime knows (because they come from real API responses and real clock measurements).

Both feed into the same `SessionEvent` stream. Downstream consumers (dispatcher, session writer, telemetry) see one unified stream and don't know or care whether an event originated from hook processing or effect execution.

### Runtime examples

**Default Erlang runtime** (`pig/agent/runtime.gleam`) — wraps the state machine in an OTP actor, takes a provider function and tool registry, spawns processes for parallel tool execution, applies hooks as middleware on effects, and sends `SessionEvent` values to the dispatcher actor.

**Test runtime** — executes effects inline with mock providers, never touches the network, applies no-op hooks, and collects effects for assertion. The entire agent loop becomes a pure fold over messages.

**JS runtime** (future) — uses `fetch` for HTTP and `Promise.all` for parallel tools, targeting the browser or Node.

### Observability and audit trail

The `SessionEvent` type is the unified audit trail. Every interesting thing that happens during an agent run — inference requests, tool executions, hook decisions, errors, session lifecycle — becomes a `SessionEvent`.

**Deterministic events** (from core state transitions): the core's `update` function is deterministic. Given the same `(state, msg)`, it always produces the same `(state, effects)`. This makes state transitions reproducible.

**Nondeterministic events** (from runtime execution and impure hooks): timing, token counts, response IDs, error details, hook decisions from database queries. These vary between runs because they depend on real-world responses and external services.

The session writer records all events to JSONL. The dispatcher fans them to any registered consumer. Telemetry projects lightweight metrics to BEAM `:telemetry`. None of these consumers know about the core/runtime split — they just consume `SessionEvent` values.

---

## What This Architecture Enables

### For library authors

- **Core is pure Gleam.** No target-specific dependencies. `gleam check` works without a runtime target. The core module (`update.gleam`) has zero imports for IO, telemetry, or hooks.
- **Trivial testing.** Every state transition is tested by constructing a `(state, msg)` pair and asserting on `StepResult`. No mocks, no HTTP stubs, no process spawning. See `update_test.gleam` and `update_scenario_test.gleam` for examples.
- **Cross-target.** Core works on Erlang and JS. Only the runtime changes per target.
- **Observability is structural.** Effects are inspectable data. Recording and replaying agent behavior is a matter of logging `(msg, state, effects)` tuples plus runtime hook decisions.
- **Smaller core.** The core has no hook logic, no observation types, no knowledge of the observability layer. It does one thing: state transitions.

### For users

- **Dry-run mode.** Run `update` without a runtime. Inspect effects. See exactly what an agent *would* request without executing anything.
- **Custom runtimes.** Control the HTTP client, retry logic, rate limiting, caching, and concurrency strategy. These are runtime concerns, not core concerns.
- **Powerful hooks.** Because hooks run in the runtime with full IO access, they can query databases, call other LLMs, check permissions services, fetch context from vector stores, redact PII via external APIs, or implement any policy that requires real-world data.
- **Human-in-the-loop.** The `on_tool_call` hook marks tools as requiring approval. The runtime implements the approval UX. Same state machine, same effect types, different interaction model.
- **Composable backpressure.** The runtime decides concurrency — sequential tools, parallel with a limit, rate-limited API calls, shared rate limits across multiple agents.
- **Deterministic replay.** Record `(msg, state)` sequences plus runtime hook decisions. Replay to verify state transitions match. Hook decisions are replayed from the recording, not re-executed.
