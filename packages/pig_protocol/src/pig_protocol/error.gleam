//// Errors that can occur during AI provider interactions.

/// Errors that can occur during AI provider interactions.
pub type AiError {
  ApiError(message: String)
  RateLimited
  Timeout
  Cancelled
  InvalidResponse(detail: String)
}
