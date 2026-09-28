//// Typed input for a fresh agent turn.

/// Caller-provided turn content. System guidance is configured separately.
pub type Input {
  User(content: String)
  Developer(content: String)
}
