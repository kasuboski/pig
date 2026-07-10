//// Shared protocols and codecs for the pig agent ecosystem.
////
//// This package contains the pure, sans-IO data structures and parsers that
//// both `pig` and `pig_proxy` use to talk to OpenAI-shaped backends.
//// It includes normalized message types, authentication helpers, Chat
//// Completions and Responses API codecs, and a pure SSE event decoder.

/// Package name, used to avoid an empty top-level module.
pub const name = "pig_protocol"
