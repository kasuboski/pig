//// Errors that can occur during AI provider interactions.

/// Errors that can occur during AI provider interactions.
pub type AiError {
  ApiError(message: String)
  RateLimited
  Timeout
  InvalidResponse(detail: String)
}
