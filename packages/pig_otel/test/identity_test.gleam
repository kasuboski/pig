//// Pure tests for Pig's bounded identity policy and span enrichment.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import pig_otel
import pig_otel/identity

pub fn identity_attributes_include_both_independent_ids_test() {
  should.equal(identity.attributes(identity.empty()), [])

  let assert Ok(session) = identity.identifier("same")
  let assert Ok(conversation) = identity.identifier("same")
  let projected =
    identity.attributes(identity.new(Some(session), Some(conversation)))
  should.equal(projected, [
    pig_otel.string_attribute("session.id", "same"),
    pig_otel.string_attribute("gen_ai.conversation.id", "same"),
  ])

  let assert Ok(other) = identity.identifier("different")
  should.equal(identity.attributes(identity.new(Some(session), Some(other))), [
    pig_otel.string_attribute("session.id", "same"),
    pig_otel.string_attribute("gen_ai.conversation.id", "different"),
  ])
  should.equal(identity.attributes(identity.new(Some(session), None)), [
    pig_otel.string_attribute("session.id", "same"),
  ])
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

pub fn identifier_validation_preserves_error_precedence_test() {
  should.equal(identity.identifier(""), Error(identity.Empty))
  should.equal(
    identity.identifier(string.repeat("a", 1023) <> "\u{FFFD}\n"),
    Error(identity.ExceedsByteLimit),
  )
  should.equal(
    identity.identifier("replacement\u{FFFD}\n"),
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
  should.equal(identity.attributes(native), [
    pig_otel.string_attribute("session.id", "session"),
    pig_otel.string_attribute("gen_ai.conversation.id", "native-conversation"),
  ])

  let unchanged = identity.with_native_conversation(baggage, None)
  should.equal(identity.attributes(unchanged), [
    pig_otel.string_attribute("session.id", "session"),
    pig_otel.string_attribute("gen_ai.conversation.id", "baggage-conversation"),
  ])
}

pub fn attributes_include_session_and_conversation_together_test() {
  let assert Ok(session) = identity.identifier("session")
  let assert Ok(conversation) = identity.identifier("conversation")
  let attributes =
    identity.attributes(identity.new(Some(session), Some(conversation)))
  should.equal(list.length(attributes), 2)
  should.equal(attributes, [
    pig_otel.string_attribute("session.id", "session"),
    pig_otel.string_attribute("gen_ai.conversation.id", "conversation"),
  ])
  should.equal(string.byte_size(identity.value(session)), 7)
}
