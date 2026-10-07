//// Validated Pig session/conversation identity and span enrichment policy.
//// This module is independent of baggage parsing and transport concerns.

import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import otel/attribute.{type Attribute}
import pig_otel

/// Maximum UTF-8 byte length accepted for either identifier.
/// 1024 bytes is a conservative bound that accommodates opaque application IDs
/// while bounding attribute/export payload growth. Values are never truncated.
pub const max_identifier_bytes = 1024

/// An exact, validated identity value.
pub opaque type Identifier {
  Identifier(String)
}

/// Why an identifier was rejected. The value itself is never included.
pub type ValidationError {
  Empty
  ContainsControlCharacter
  ContainsReplacementCharacter
  ExceedsByteLimit
}

/// Independently optional session and conversation identifiers.
pub opaque type Identity {
  Identity(session_id: Option(Identifier), conversation_id: Option(Identifier))
}

/// Validate and retain the exact input; reject instead of trimming, hashing,
/// normalizing, or truncating it. Control means Unicode C0/C1 controls.
pub fn identifier(value: String) -> Result(Identifier, ValidationError) {
  use <- bool.guard(when: string.is_empty(value), return: Error(Empty))
  use <- bool.guard(
    when: string.byte_size(value) > max_identifier_bytes,
    return: Error(ExceedsByteLimit),
  )
  use <- bool.guard(
    when: list.any(string.to_utf_codepoints(value), fn(codepoint) {
      string.utf_codepoint_to_int(codepoint) == 65_533
    }),
    return: Error(ContainsReplacementCharacter),
  )
  use <- bool.guard(
    when: list.any(string.to_utf_codepoints(value), fn(codepoint) {
      let codepoint = string.utf_codepoint_to_int(codepoint)
      codepoint <= 31 || { codepoint >= 127 && codepoint <= 159 }
    }),
    return: Error(ContainsControlCharacter),
  )
  Ok(Identifier(value))
}

/// A request with no session or conversation identity.
pub fn empty() -> Identity {
  Identity(session_id: None, conversation_id: None)
}

/// Create an identity from independently validated identifiers.
pub fn new(
  session_id: Option(Identifier),
  conversation_id: Option(Identifier),
) -> Identity {
  Identity(session_id:, conversation_id:)
}

/// Validate and set a session ID, leaving all other identity state unchanged.
pub fn with_session(
  identity: Identity,
  value: Result(Identifier, ValidationError),
) -> Identity {
  case identity, value {
    Identity(_, conversation_id), Ok(value) ->
      Identity(session_id: Some(value), conversation_id:)
    identity, _ -> identity
  }
}

/// Validate and set a conversation ID, leaving all other identity state unchanged.
pub fn with_conversation(
  identity: Identity,
  value: Result(Identifier, ValidationError),
) -> Identity {
  case identity, value {
    Identity(session_id, _), Ok(value) ->
      Identity(session_id:, conversation_id: Some(value))
    identity, _ -> identity
  }
}

/// Select the effective conversation ID. A valid native value takes precedence
/// over the identity's conversation value; session identity is unchanged.
pub fn with_native_conversation(
  identity: Identity,
  native_conversation_id: Option(Identifier),
) -> Identity {
  case identity, native_conversation_id {
    Identity(session_id:, conversation_id: _), Some(native) ->
      Identity(session_id:, conversation_id: Some(native))
    identity, None -> identity
  }
}

/// Convert the identity directly to Pig-owned OTel attributes, with no
/// arbitrary attribute map and no dependency on baggage APIs.
pub fn attributes(identity: Identity) -> List(Attribute) {
  let Identity(session_id, conversation_id) = identity
  let session = case session_id {
    None -> []
    Some(identifier) -> [
      pig_otel.string_attribute("session.id", value(identifier)),
    ]
  }
  let conversation = case conversation_id {
    None -> []
    Some(identifier) -> [
      pig_otel.string_attribute("gen_ai.conversation.id", value(identifier)),
    ]
  }
  list.append(session, conversation)
}

/// Read the exact accepted identifier, for policy adapters and callers.
pub fn value(identifier: Identifier) -> String {
  let Identifier(value) = identifier
  value
}
