import gleam/option.{type Option, None, Some}
import gleeunit/should
import pig/ai/message.{type Message, Assistant}
import pig/ai/provider.{
  type InferenceMetadata, type InferenceResult, default_metadata, from_message,
  with_finish_reason, with_input_tokens, with_output_tokens, with_response_id,
  with_response_model,
}

/// Check that from_message preserves the original message
fn check_result_preserves_message(message: Message) {
  let result = from_message(message)
  should.equal(result.message, message)
}

/// Check that default metadata has None for all optional fields
fn check_default_has_none_fields(result: InferenceResult) {
  should.equal(result.metadata.response_id, None)
  should.equal(result.metadata.response_model, None)
  should.equal(result.metadata.finish_reason, None)
  should.equal(result.metadata.input_tokens, None)
  should.equal(result.metadata.output_tokens, None)
}

/// Check that a setter applies a value to a metadata field
fn check_metadata_setter(
  meta: InferenceMetadata,
  setter: fn(InferenceMetadata, a) -> InferenceMetadata,
  field_accessor: fn(InferenceMetadata) -> Option(a),
  value: a,
) {
  let updated = setter(meta, value)
  should.equal(field_accessor(updated), Some(value))
}

pub fn result_preserves_message_test() {
  let msg = Assistant("hi", [], None)
  check_result_preserves_message(msg)
}

pub fn default_metadata_has_none_fields_test() {
  let msg = Assistant("hi", [], None)
  let result = from_message(msg)
  check_default_has_none_fields(result)
}

pub fn setter_response_id_applies_test() {
  let meta = default_metadata()
  check_metadata_setter(
    meta,
    with_response_id,
    fn(m) { m.response_id },
    "resp-123",
  )
}

pub fn setter_input_tokens_applies_test() {
  let meta = default_metadata()
  check_metadata_setter(meta, with_input_tokens, fn(m) { m.input_tokens }, 42)
}

pub fn all_setters_apply_test() {
  let meta = default_metadata()
  check_metadata_setter(
    meta,
    with_response_id,
    fn(m) { m.response_id },
    "resp-456",
  )
  check_metadata_setter(
    meta,
    with_response_model,
    fn(m) { m.response_model },
    "gpt-4",
  )
  check_metadata_setter(
    meta,
    with_finish_reason,
    fn(m) { m.finish_reason },
    "stop",
  )
  check_metadata_setter(meta, with_input_tokens, fn(m) { m.input_tokens }, 100)
  check_metadata_setter(meta, with_output_tokens, fn(m) { m.output_tokens }, 50)
}

pub fn equality_of_identically_constructed_test() {
  let meta1 =
    default_metadata()
    |> with_response_id("resp-789")
    |> with_response_model("gpt-4")
    |> with_finish_reason("stop")
    |> with_input_tokens(200)
    |> with_output_tokens(100)

  let meta2 =
    default_metadata()
    |> with_response_id("resp-789")
    |> with_response_model("gpt-4")
    |> with_finish_reason("stop")
    |> with_input_tokens(200)
    |> with_output_tokens(100)

  should.equal(meta1, meta2)
}
