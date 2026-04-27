import pig/ai/provider.{default_metadata, from_message, with_response_id, with_input_tokens, with_response_model, with_finish_reason, with_output_tokens}
import pig/ai/message.{Assistant}
import gleam/option.{None, Some}
import gleeunit/should

pub fn from_message_wraps_message_test() {
  let msg = Assistant("hi", [], None)
  let result = from_message(msg)

  result.message
  |> should.equal(msg)
}

pub fn from_message_default_metadata_has_none_fields_test() {
  let msg = Assistant("hi", [], None)
  let result = from_message(msg)

  result.metadata.response_id
  |> should.equal(None)

  result.metadata.response_model
  |> should.equal(None)

  result.metadata.finish_reason
  |> should.equal(None)

  result.metadata.input_tokens
  |> should.equal(None)

  result.metadata.output_tokens
  |> should.equal(None)
}

pub fn with_response_id_test() {
  let meta = default_metadata()
  let updated = with_response_id(meta, "resp-123")

  updated.response_id
  |> should.equal(Some("resp-123"))
}

pub fn with_input_tokens_test() {
  let meta = default_metadata()
  let updated = with_input_tokens(meta, 42)

  updated.input_tokens
  |> should.equal(Some(42))
}

pub fn with_all_fields_test() {
  let meta =
    default_metadata()
    |> with_response_id("resp-456")
    |> with_response_model("gpt-4")
    |> with_finish_reason("stop")
    |> with_input_tokens(100)
    |> with_output_tokens(50)

  meta.response_id
  |> should.equal(Some("resp-456"))

  meta.response_model
  |> should.equal(Some("gpt-4"))

  meta.finish_reason
  |> should.equal(Some("stop"))

  meta.input_tokens
  |> should.equal(Some(100))

  meta.output_tokens
  |> should.equal(Some(50))
}

pub fn equality_test() {
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

  meta1
  |> should.equal(meta2)
}
