//// Pure tests for Pig's bounded identity policy and span enrichment.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import pig_otel
import pig_otel/identity

pub fn absent_identity_and_independent_ids_test() {
  let absent = identity.for_span(identity.empty(), identity.LogicalInference)
  should.equal(absent, identity.Enrichment(None, None))

  let assert Ok(session) = identity.identifier("same")
  let assert Ok(conversation) = identity.identifier("same")
  let projection =
    identity.for_span(
      identity.new(Some(session), Some(conversation)),
      identity.LogicalInference,
    )
  should.equal(
    projection,
    identity.Enrichment(Some(session), Some(conversation)),
  )

  let assert Ok(other) = identity.identifier("different")
  let independent =
    identity.for_span(
      identity.new(Some(session), Some(other)),
      identity.LogicalInference,
    )
  should.equal(independent, identity.Enrichment(Some(session), Some(other)))

  let no_derived_conversation =
    identity.for_span(
      identity.new(Some(session), None),
      identity.LogicalInference,
    )
  should.equal(
    no_derived_conversation,
    identity.Enrichment(Some(session), None),
  )
}

pub fn identifier_preserves_exact_unicode_and_escaped_text_test() {
  let original = "  café/%2F/\u{1F642}  "
  let assert Ok(identifier) = identity.identifier(original)
  should.equal(identity.value(identifier), original)
}

pub fn identifier_uses_utf8_byte_bound_test() {
  let at_limit = string.repeat("é", 512)
  should.equal(string.byte_size(at_limit), identity.max_identifier_bytes)
  let assert Ok(identifier) = identity.identifier(at_limit)
  should.equal(identity.value(identifier), at_limit)

  let over_limit = string.repeat("é", 513)
  should.equal(
    string.byte_size(over_limit) > identity.max_identifier_bytes,
    True,
  )
  should.equal(
    identity.identifier(over_limit),
    Error(identity.ExceedsByteLimit),
  )
}

pub fn identifier_rejects_empty_and_unicode_control_characters_test() {
  should.equal(identity.identifier(""), Error(identity.Empty))
  should.equal(
    identity.identifier("before\n after"),
    Error(identity.ContainsControlCharacter),
  )
  should.equal(
    identity.identifier("tab\tvalue"),
    Error(identity.ContainsControlCharacter),
  )
  should.equal(
    identity.identifier("c1\u{0085}control"),
    Error(identity.ContainsControlCharacter),
  )
  should.equal(
    identity.identifier("replacement\u{FFFD}character"),
    Error(identity.ContainsReplacementCharacter),
  )
}

pub fn native_conversation_precedes_validated_baggage_value_test() {
  let assert Ok(session) = identity.identifier("session")
  let assert Ok(baggage_conversation) =
    identity.identifier("baggage-conversation")
  let assert Ok(native_conversation) =
    identity.identifier("native-conversation")
  let baggage = identity.new(Some(session), Some(baggage_conversation))
  let native =
    identity.with_native_conversation(baggage, Some(native_conversation))
  let identity.Enrichment(session_id:, conversation_id:) =
    identity.for_span(native, identity.LogicalInference)
  should.equal(session_id, Some(session))
  should.equal(conversation_id, Some(native_conversation))

  let unchanged = identity.with_native_conversation(baggage, None)
  let identity.Enrichment(_, conversation_id) =
    identity.for_span(unchanged, identity.LogicalInference)
  should.equal(conversation_id, Some(baggage_conversation))
}

pub fn enrichment_is_role_specific_and_metadata_only_test() {
  let assert Ok(session) = identity.identifier("session")
  let assert Ok(conversation) = identity.identifier("conversation")
  let value = identity.new(Some(session), Some(conversation))

  let server = identity.for_span(value, identity.ProxyServer)
  should.equal(server, identity.Enrichment(Some(session), None))
  let logical = identity.for_span(value, identity.LogicalInference)
  should.equal(logical, identity.Enrichment(Some(session), Some(conversation)))
  let attempt = identity.for_span(value, identity.PhysicalAttempt)
  should.equal(attempt, identity.Enrichment(Some(session), None))

  should.equal(list.length(identity.attributes(server)), 1)
  should.equal(list.length(identity.attributes(logical)), 2)
  should.equal(list.length(identity.attributes(attempt)), 1)
  should.equal(identity.attributes(logical), [
    pig_otel.string_attribute("session.id", "session"),
    pig_otel.string_attribute("gen_ai.conversation.id", "conversation"),
  ])
  should.equal(string.byte_size(identity.value(session)), 7)
}
