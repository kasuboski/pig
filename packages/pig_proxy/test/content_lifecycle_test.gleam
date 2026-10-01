import gleam/list
import gleam/string
import gleeunit/should
import pig_otel
import pig_proxy/config
import pig_proxy/content
import support/content_lifecycle_harness as check

pub fn builder_precedence_is_last_explicit_call_wins_test() {
  let capture_after_disabled =
    config.new([])
    |> config.with_tracing(pig_otel.Disabled)
    |> config.with_conversation_capture(content.defaults())
  let assert config.Conversation(_) = capture_after_disabled.tracing

  let metadata_after_capture =
    config.new([])
    |> config.with_conversation_capture(content.defaults())
    |> config.with_tracing(pig_otel.MetadataOnly)
  should.equal(metadata_after_capture.tracing, config.MetadataOnly)

  let disabled_after_capture =
    config.new([])
    |> config.with_conversation_capture(content.defaults())
    |> config.with_tracing(pig_otel.Disabled)
  should.equal(disabled_after_capture.tracing, config.Disabled)
}

pub fn default_config_remains_metadata_only_test() {
  let assert config.MetadataOnly = config.new([]).tracing
  let assert config.MetadataOnly = config.from_env().tracing
}

pub fn skipped_targets_do_not_capture_unsent_input_test() {
  let annotations = check.run_no_target_capture()
  let all = list.fold(annotations, "", fn(acc, value) { acc <> value })
  should.equal(string.contains(all, "gen_ai.input.messages"), False)
  should.equal(string.contains(all, "gen_ai.output.messages"), False)
}

pub fn buffered_capture_respects_encoding_and_exact_media_type_test() {
  list.each([pig_otel.ChatCompletions, pig_otel.Responses], fn(api) {
    list.each(check.eligibility_cases(), fn(row) {
      let annotations = check.check_eligibility(api, row)
      let all = list.fold(annotations, "", fn(acc, value) { acc <> value })
      should.equal(
        #(row.name, string.contains(all, "gen_ai.input.messages")),
        #(row.name, row.input),
      )
      should.equal(
        #(row.name, string.contains(all, "gen_ai.output.messages")),
        #(row.name, row.output),
      )
    })
  })
}

pub fn buffered_source_limit_precedes_utf8_validation_test() {
  let annotations = check.check_oversized_before_utf8()
  let all = list.fold(annotations, "", fn(acc, value) { acc <> value })
  should.equal(string.contains(all, "source_limit"), True)
  should.equal(string.contains(all, "gen_ai.output.messages"), False)
}

pub fn retry_body_is_never_attached_only_selected_logical_response_test() {
  let annotations = check.run_retrying_buffered_capture()
  let all = list.fold(annotations, "", fn(acc, value) { acc <> value })
  should.equal(string.contains(all, "gen_ai.input.messages"), True)
  should.equal(string.contains(all, "gen_ai.output.messages"), True)
  should.equal(string.contains(all, "fixture answer"), True)
  should.equal(string.contains(all, "PRIVATE_RETRY_ENVELOPE"), False)
}
