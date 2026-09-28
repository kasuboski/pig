//// Errors that can occur during AI provider interactions.

import pig_protocol/message.{type Role}

/// Errors that can occur during AI provider interactions.
pub type AiError {
  ApiError(message: String)
  RateLimited
  Timeout
  Cancelled
  InvalidResponse(detail: String)
  UnsupportedMessageRole(role: Role)
}
