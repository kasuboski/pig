# Durable Developer-Initiated Turns

Status: implemented; local check, test, and build pass. Opt-in live-provider tests were not run.

Issue: https://github.com/kasuboski/pig/issues/29

Design direction agreed in discussion: use Developer, not System, for
application-initiated conversation turns. Keep the standing System prompt and
the convenient String-based User interface. Backwards compatibility is not a
design constraint beyond retaining that useful default interface.

This document is the implementation specification and supersedes the issue's
System-turn wording. Implement Developer turns, not historical System turns.
Updating the issue to match is documentation follow-up, not an implementation
prerequisite. The filename retains the original issue topic.

## Role model

- System: configured standing guidance, not a new conversation turn.
- Developer: application-originated input that initiates a normal, tool-capable
  turn. It can carry steering instructions, updated context or constraints,
  background outcomes, or any other update the application wants to provide.
- User: ordinary caller prompts, including the existing String-based interface.
- Assistant and Tool: generated conversation progress, never fresh turn inputs.

Developer describes the input's source and authority, not its purpose. Background
outcomes are one example, not a special message category or required payload.
Developer content is privileged application speech, not a Tool result or a
fabricated User message. The caller owns its construction and trust. Pig should
not claim that every model interprets System versus Developer identically;
provider support and instruction precedence are model-specific.

Yard/Verde own durable admission, external notification deduplication, outcome
construction, and display. No scheduler or special summarization loop in Pig.

## Public interface

Introduce `pig/turn.gleam` with a restricted input union:

```gleam
pub type Input {
  User(content: String)
  Developer(content: String)
}
```

Keep the simple interface:

```gleam
pig.run(agent, "Review this contract")
```

Add explicit typed entrypoints on standalone and supervised agents:

```gleam
pig.run_turn(agent, turn.Developer("Focus on security; do not modify files."))
pig.run_turn(agent, turn.Developer("Contract generation finished: contract=42"))
pig.run_turn(agent, turn.User("Review this contract"))
```

- `run_turn(agent, input) -> Result(Message, RunError)`
- `run_turn_with_timeout(agent, input, timeout_ms) -> Result(Message, RunError)`
- `stream_turn(agent, input, sink) -> Result(Run, RunStartError)`
- `stream_turn_owned(agent, input, sink, owner) -> Result(Run, RunStartError)`

Use turn.Input for input, Subject(RunEvent) for sink, Pid for owner, and Int
milliseconds for timeout_ms. Use the existing 120_000 ms default for run_turn.
On pig/supervisor, substitute SupervisedAgent for Agent with identical behavior.
Reuse the existing error mapping, collector, owner watching, and cancellation
semantics rather than introducing another handle or result type.

String-based run/stream variants delegate through turn.User. Keep continuation
separate: it resumes committed history and does not accept or append new input.
Do not accept unrestricted protocol Message values or a role string for fresh
turns. Do not add separate Developer-only execution logic or new try wrappers.

## Protocol representation

Add Developer(content: String) and DeveloperRole to
`packages/pig_protocol/src/pig_protocol/message.gleam` and its role function.
Retain System for standing-prompt transport representation.

Update both codecs, session JSON encoding/decoding, and all exhaustive message
matches. Persist Developer with the literal role `developer`; never convert it
to System or User on serialization, reload, or replay.

The SessionStore contract already carries normalized Message values, so no new
commit kind or turn envelope is needed. External store implementations must
update their own encoders/decoders to handle the new role.

## One execution and recovery path

Replace the pure core UserPrompt message with StartTurn(Input). Runtime start
helpers route through one typed start message. The pure transition appends the
corresponding protocol message and returns CallProvider with the usual tools.

Use the existing ordering in agent/runtime.gleam:advance:

1. Accept the run using existing Busy and pending-commit checks.
2. Compute candidate history with the input appended once.
3. Commit its delta through SessionStore.
4. Only after successful commit, run inference hooks and start the provider.
5. Use normal tools, cancellation, events, and completion.

A trailing Developer message chooses StartInference during recovery, just like
User. Existing assistant/tool progress recovery stays unchanged. Seeded history,
standalone load, supervised restart, JSONL replay, and settings conflict recovery
must retain Developer messages in order.

A failed commit starts no inference. Ambiguous in-process retries reuse the
existing commit identity and candidate state. After restart, reload committed
history and continue without resubmitting the input.

Guarantees and limits:

- Crash durability requires a durable SessionStore; SessionDisabled remains valid.
- Successful stream start / RunStarted means accepted, not committed.
- Starting a turn during an active run returns Busy; no queue, interruption, or
  injection into an in-flight inference is added. Steering describes content,
  not a new concurrency mechanism.
- Restart reloads state; the caller invokes run_continue/stream_continue to
  resume. This feature does not add automatic execution on process startup.
- Another run_turn call is another turn, even with identical content. Retrying a
  committed turn means continuation. External admission remains caller-owned.
- No new exactly-once inference or tool-side-effect guarantee.
- JSONL replay remains best-effort; the asynchronous trace writer cannot replace
  the durable input checkpoint.

## Standing guidance stays separate

Add `system_prompt: Option(String)` to provider.InferenceRequest. Its messages
contain conversation history, including Developer turns, not the configured
prompt. The resulting request has this shape:

```gleam
pub type InferenceRequest {
  InferenceRequest(
    system_prompt: Option(String),
    messages: List(Message),
    tools: List(ToolDefinition),
    settings: InferenceSettings,
  )
}
```

Update all direct request constructors, including tests, examples, and custom
provider examples. Use None when no standing guidance is configured.

The standing prompt still appears first for Chat Completions; separation is an
internal representation improvement, not a change to the configured prompt.
Responses already has a dedicated instructions field. Neither adapter needs to
extract standing guidance from an undifferentiated list of messages.

Keep CallProvider focused on history and tools. The runtime reads the standing
prompt from AgentConfig when constructing InferenceRequest. Replace the helper
that prepends System before hooks with direct conversation history access.

Add `system_prompt: Option(String)` to hooks.BeforeInferenceEvent and preserve
it through hook composition. Hooks inspect it separately; messages and
ReplaceMessages operate on conversation only. Standing guidance remains
configuration-owned. Transformations remain request-local and do not rewrite
committed input. Do not add a standing-prompt replacement action.

Inference event input_messages retain their current post-hook meaning but now
exclude injected standing guidance. They include Developer messages so new
traces replay those turns. Document counts as conversation-message counts. No
new role-specific event family or duplicate logging is necessary.

## Provider encoding

For standing guidance G and history `[User(U), Assistant(A), Developer(D)]`:

### Chat Completions

The OpenAI adapter prepends System(G) at the encoding step. Extend the chat codec
to encode Developer with role `developer` and ordinary text content:

```text
messages = [System(G), User(U), Assistant(A), Developer(D)]
```

### Responses

Pass system_prompt directly as instructions; remove the helper that collects
System messages. Add Developer input items with role `developer` and input_text
content. Do not move Developer content into instructions:

```text
instructions = G
input = [User(U), Assistant(A), Developer(D)]
```

Buffered and streaming builders use the same mapping. On subsequent turns,
replay D at its original position, including assistant and tool progress.
Without standing guidance, omit instructions but retain Developer input.

### Unsupported providers/models

Use an explicit error rather than silently dropping, hoisting, or relabeling a
Developer message. Add `UnsupportedMessageRole(role: Role)` to AiError in
pig_protocol/error.gleam, importing Role from pig_protocol/message.gleam.
DeveloperRole identifies this case. Update exhaustive error handling and any
error rendering/serialization affected by the new variant.

Custom adapters that know the role is unsupported fail before upstream IO using
the normal Finished(Error(...)) path. If an OpenAI-compatible endpoint/model
rejects the role, surface its API error without retrying as User or System.
The committed input remains available for continuation with a suitable provider.
Do not add a capability registry, model allowlist, or automatic role fallback.

## Legacy System history

Do not add migration machinery or infer that old System entries were Developer
turns. Preserve the existing agent load policy that excludes System entries from
seeded/restored conversation history: System is configuration-owned, Developer
is the new durable in-band role. Update comments to state this role distinction.

Consequently the current strip_system_messages helper can remain; it must never
strip Developer. Low-level System transport support need not be removed.

Old transcripts that used System for application events require explicit caller
conversion to Developer if those events should become turns. No automatic text
matching, position heuristic, compatibility flag, or legacy replay guarantee.

## Verification

Follow knowledge/TESTING_STRATEGY.md: centralized check helpers, data-driven pure
scenarios, and narrow OTP tests for actual ordering and resilience.

- Pure transitions: User and Developer inputs append once, expose tools, and use
  identical assistant/tool iteration behavior. System is not a turn input.
- Recovery: trailing Developer begins inference; assistant/tool behavior remains.
- Runtime: controlled store/provider handshakes prove commit-before-inference;
  failed/ambiguous commits start no provider work. Do not use sleeps.
- Crash scenarios: restart after input commit, after tool progress, and after
  final assistant commit retains Developer input once; pending retry is idempotent.
- Lifecycle: Developer input can call tools and return a final Assistant;
  cancellation and terminal events use the ordinary path.
- Persistence: seeds, durable startup, supervised restart, JSONL round-trip, and
  settings-conflict recovery preserve Developer. Legacy System is not promoted.
- Request fixtures for both adapters: standing prompt, User, Assistant, later
  Developer, then replay on another turn including tool progress. Cover absent
  standing prompt and Developer text identical to standing guidance.
- Verify configured adapter wiring as well as pure buffered/streaming codecs.
- Hooks preserve independent guidance while replacing conversation messages.
- Unsupported role produces an explicit error without recasting the input.
- Existing pig.run(agent, String) and stream conveniences continue to work.
- Run mise run check, mise run test, and mise run build with zero warnings.
  Any live-provider verification belongs in the opt-in integration suite.

## Implementation sequence

1. Add normalized Developer role and codec/session round-trip support.
2. Separate standing guidance through requests, hooks, and inference traces;
   update constructors and adapter fixtures.
3. Add typed turn entrypoints and Developer recovery through the existing
   commit/effect loop. Cover all load paths and durable crash/retry scenarios.
4. Update issue acceptance wording, docs, examples, and architecture specification;
   run formatting, all tests, and the complete library/example build.

## Implementation map

Paths below are relative to the repository root. They identify the primary
change sites, not a substitute for following compiler exhaustiveness errors.

| Files | Work |
| --- | --- |
| `packages/pig/src/pig/turn.gleam` (new) | Restricted User/Developer input type. |
| `packages/pig/src/pig.gleam`, `packages/pig/src/pig/supervisor.gleam` | Typed entrypoints and String-based delegation. |
| `packages/pig/src/pig/agent/msg.gleam`, `packages/pig/src/pig/agent/update.gleam` | One typed start transition and ordinary effects. |
| `packages/pig/src/pig/agent/state.gleam`, `packages/pig/src/pig/agent/runtime.gleam` | Conversation-only effects, explicit provider guidance, and shared runtime entrypoints. |
| `packages/pig/src/pig/agent/run_recovery.gleam`, `packages/pig/src/pig/agent/durable_session.gleam` | Developer continuation and preservation through recovery; retain existing commit machinery. |
| `packages/pig/src/pig/provider.gleam`, `packages/pig/src/pig/hooks.gleam` | Separated standing guidance and documented custom-provider contract. |
| `packages/pig/src/pig/openai.gleam` | Explicit guidance mapping instead of System-message extraction. |
| `packages/pig_protocol/src/pig_protocol/message.gleam`, `packages/pig_protocol/src/pig_protocol/error.gleam` | Developer/DeveloperRole and UnsupportedMessageRole. |
| `packages/pig_protocol/src/pig_protocol/codec/chat.gleam`, `packages/pig_protocol/src/pig_protocol/codec/responses.gleam` | Developer request encoding in buffered and streaming builders. |
| `packages/pig/src/pig/obs/session.gleam` | Developer JSON encode/decode and replay coverage. |

Extend existing test domains rather than creating parallel role-specific suites:

- `packages/pig/test/support/harness.gleam` and
  `packages/pig/test/support/openai_harness.gleam`: centralize changed setup.
- `packages/pig/test/pig/agent/`: pure scenarios and runtime durability tests.
- `packages/pig/test/pig/pig_config_test.gleam` and
  `packages/pig/test/pig/obs/`: seed/load/replay and role serialization.
- `packages/pig/test/pig/openai_test.gleam`,
  `packages/pig/test/pig/openai_stream_test.gleam`, and
  `packages/pig_protocol/test/codec/`: adapter wiring and request fixtures.
- Inspect wildcard message/error matches as well as compiler errors: adding a
  union variant does not expose silently ignored cases hidden by catch-all arms.

## Definition of done

The Verification section is the acceptance checklist. All scenarios must pass,
including durable commit ordering, recovery without duplicate input, full
Developer role round-trip, unchanged User convenience calls, and both provider
encodings. Public docs must explain general application input, Busy behavior,
explicit continuation, durability limits, and unsupported-provider behavior.

Update knowledge/SPEC.md where its older interface descriptions conflict with
this implementation, and keep examples and custom-provider documentation in
sync. Run formatting and all three mise validation tasks with zero compiler
warnings. Record any opt-in live tests not run separately from the local checks.

There are no remaining product/interface decisions required to start
implementation. This document defines the intended behavior; passing builds,
tests, and implementation review are still required before shipping.
