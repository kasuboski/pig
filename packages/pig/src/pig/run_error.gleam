//// Typed errors and cancellation reasons for agent runs.

import pig/session_store.{type SessionError}
import pig_protocol/error.{type AiError}

/// Why an active run was cancelled.
pub type CancelReason {
  /// The caller explicitly requested cancellation.
  CallerRequested
  /// A collecting adapter reached its deadline.
  DeadlineExceeded
  /// The process responsible for the client stream exited.
  ClientDisconnected
  /// The owning agent was stopped.
  AgentStopped
}

/// Errors returned while running an agent.
pub type RunError {
  /// The inference provider failed.
  Inference(error: AiError)
  /// Loading or committing the durable session failed.
  Session(error: SessionError)
  /// The active run was cancelled.
  Cancelled(reason: CancelReason)
  /// The runtime process was no longer available to finish the run.
  RuntimeUnavailable
  /// The runtime failed independently of inference or session storage.
  Runtime(message: String)
}

/// Errors that prevent a run from being accepted.
pub type RunStartError {
  /// This agent already has an active run.
  Busy
  /// Durable recovery or another runtime fence rejected the request.
  Rejected(error: RunError)
  /// The runtime did not accept the request before the start deadline.
  RuntimeStartUnavailable
}
