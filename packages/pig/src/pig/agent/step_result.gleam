//// Step result type for the sans-IO core.
////
//// The outcome of a single state transition — what happened after
//// processing a message. Carries the new state and optional effects.
////
//// Three variants:
////   - `Done`      — the agent produced a final answer
////   - `Continue`  — the agent needs more work (inference, tools)
////   - `Failed`    — an unrecoverable error occurred

import pig/agent/effect.{type Effect}
import pig/agent/state.{type AgentState}
import pig_protocol/error.{type AiError}
import pig_protocol/message.{type Message}

/// Result of a single state transition in the agent loop.
pub type StepResult(msg) {
  /// The agent produced a final answer. No further effects needed.
  Done(state: AgentState, message: Message)

  /// The agent needs more work. Contains effects for the runtime to execute.
  Continue(state: AgentState, effects: List(Effect(msg)))

  /// An unrecoverable error occurred.
  Failed(state: AgentState, error: AiError)
}
