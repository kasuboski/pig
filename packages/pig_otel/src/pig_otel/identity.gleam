//// Validated Pig session/conversation identity and span enrichment policy.
//// This module is independent of baggage parsing and transport concerns.

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

/// Span classes currently relevant to proxy identity enrichment.
pub type SpanRole {
  ProxyServer
  LogicalInference
  PhysicalAttempt
}

/// Identity projection selected for a particular span role.
/// A session is carried on every proxy span; conversation is semantic only.
pub type Enrichment {
  Enrichment(
    session_id: Option(Identifier),
    conversation_id: Option(Identifier),
  )
}

/// Validate and retain the exact input; reject instead of trimming, hashing,
/// normalizing, or truncating it. Control means Unicode C0/C1 controls.
pub fn identifier(value: String) -> Result(Identifier, ValidationError) {
  let size = string.byte_size(value)
  case string.is_empty(value) {
    True -> Error(Empty)
    False ->
      case size > max_identifier_bytes {
        True -> Error(ExceedsByteLimit)
        False ->
          case
            list.any(string.to_utf_codepoints(value), fn(codepoint) {
              string.utf_codepoint_to_int(codepoint) == 65_533
            })
          {
            True -> Error(ContainsReplacementCharacter)
            False ->
              case
                list.any(string.to_utf_codepoints(value), fn(codepoint) {
                  let codepoint = string.utf_codepoint_to_int(codepoint)
                  codepoint <= 31 || { codepoint >= 127 && codepoint <= 159 }
                })
              {
                True -> Error(ContainsControlCharacter)
                False -> Ok(Identifier(value))
              }
          }
      }
  }
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

/// Pure per-span identity projection. Session appears on server, logical, and
/// physical proxy spans; conversation appears only on logical inference spans.
pub fn for_span(identity: Identity, role: SpanRole) -> Enrichment {
  case identity {
    Identity(session_id:, conversation_id:) ->
      Enrichment(session_id:, conversation_id: case role {
        LogicalInference -> conversation_id
        ProxyServer | PhysicalAttempt -> None
      })
  }
}

/// Convert the policy projection to Pig-owned OTel attributes, with no arbitrary
/// attribute map and no dependency on baggage APIs.
pub fn attributes(enrichment: Enrichment) -> List(Attribute) {
  case enrichment {
    Enrichment(session_id, conversation_id) -> {
      let session = case session_id {
        None -> []
        Some(value) -> [
          pig_otel.string_attribute("session.id", value_string(value)),
        ]
      }
      let conversation = case conversation_id {
        None -> []
        Some(value) -> [
          pig_otel.string_attribute(
            "gen_ai.conversation.id",
            value_string(value),
          ),
        ]
      }
      list.append(session, conversation)
    }
  }
}

/// Read the exact accepted identifier, for policy adapters and callers.
pub fn value(identifier: Identifier) -> String {
  let Identifier(value) = identifier
  value
}

fn value_string(value: Identifier) -> String {
  let Identifier(raw) = value
  raw
}
