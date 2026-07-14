//// Errors returned while running an agent.

import pig/session_store.{type SessionError}
import pig_protocol/error.{type AiError}

/// Errors from inference, durable session storage, or the agent runtime.
pub type RunError {
  /// The inference provider failed.
  Inference(error: AiError)
  /// Loading or committing the durable session failed.
  Session(error: SessionError)
  /// The runtime failed independently of inference or session storage.
  Runtime(message: String)
}
