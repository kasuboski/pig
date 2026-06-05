import gleam/option.{type Option, None, Some}
import pig/ai/message.{type Message, Assistant}
import pig/ai/provider.{
  type InferenceMetadata, type InferenceResult, default_metadata, from_message,
  with_stop_reason, with_input_tokens, with_output_tokens, with_response_id,
  with_response_model,
}
import pig/ai/stop_reason

/// Check that from_message preserves the original message
fn check_result_preserves_message(message: Message) {
  let result = from_message(message)
  assert result.message == message
}

/// Check that default metadata has None for all optional fields
fn check_default_has_none_fields(result: InferenceResult) {
  assert result.metadata.response_id == None
  assert result.metadata.response_model == None
  assert result.metadata.stop_reason == None
  assert result.metadata.input_tokens == None
  assert result.metadata.output_tokens == None
}

/// Check that a setter applies a value to a metadata field
fn check_metadata_setter(
  meta: InferenceMetadata,
  setter: fn(InferenceMetadata, a) -> InferenceMetadata,
  field_accessor: fn(InferenceMetadata) -> Option(a),
  value: a,
) {
  let updated = setter(meta, value)
  assert field_accessor(updated) == Some(value)
}

pub fn result_preserves_message_test() {
  let msg = Assistant("hi", [], None, None)
  check_result_preserves_message(msg)
}

pub fn default_metadata_has_none_fields_test() {
  let msg = Assistant("hi", [], None, None)
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
    with_stop_reason,
    fn(m) { m.stop_reason },
    stop_reason.Stop,
  )
  check_metadata_setter(meta, with_input_tokens, fn(m) { m.input_tokens }, 100)
  check_metadata_setter(meta, with_output_tokens, fn(m) { m.output_tokens }, 50)
}

pub fn equality_of_identically_constructed_test() {
  let meta1 =
    default_metadata()
    |> with_response_id("resp-789")
    |> with_response_model("gpt-4")
    |> with_stop_reason(stop_reason.Stop)
    |> with_input_tokens(200)
    |> with_output_tokens(100)

  let meta2 =
    default_metadata()
    |> with_response_id("resp-789")
    |> with_response_model("gpt-4")
    |> with_stop_reason(stop_reason.Stop)
    |> with_input_tokens(200)
    |> with_output_tokens(100)

  assert meta1 == meta2
}
