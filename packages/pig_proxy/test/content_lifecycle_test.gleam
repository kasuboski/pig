import gleam/list
import gleam/string
import gleeunit/should
import pig_otel
import pig_otel/content/options
import pig_proxy/config
import support/content_lifecycle_harness as check

pub fn policy_builder_last_call_wins_test() {
  let capture = pig_otel.Conversation(options.defaults())
  let capture_after_disabled =
    config.new([])
    |> config.with_tracing(pig_otel.Disabled)
    |> config.with_tracing(capture)
  let assert pig_otel.Conversation(_) = capture_after_disabled.tracing

  let metadata =
    config.new([])
    |> config.with_tracing(capture)
    |> config.with_tracing(pig_otel.MetadataOnly)
  should.equal(metadata.tracing, pig_otel.MetadataOnly)

  let disabled =
    config.new([])
    |> config.with_tracing(capture)
    |> config.with_tracing(pig_otel.Disabled)
  should.equal(disabled.tracing, pig_otel.Disabled)
}

pub fn default_config_remains_metadata_only_test() {
  let assert pig_otel.MetadataOnly = config.new([]).tracing
  let assert pig_otel.MetadataOnly = config.from_env().tracing
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

pub fn large_responses_completion_keeps_real_span_metadata_test() {
  let assert Ok(small_capture) =
    options.with_direction_limits(
      options.defaults(),
      options.OutputLimits(1024, 1024),
    )
  list.each(
    [pig_otel.MetadataOnly, pig_otel.Conversation(small_capture)],
    fn(policy) {
      let annotations = check.run_large_completion(policy)
      should.be_true(
        list.any(annotations, fn(attributes) {
          attributes
          == "[{attribute,{key,<<\"gen_ai.response.id\">>},\n            {string_value,<<\"fixture-response-id\">>}},\n {attribute,{key,<<\"gen_ai.response.model\">>},\n            {string_value,<<\"fixture-response-model\">>}},\n {attribute,{key,<<\"gen_ai.response.finish_reasons\">>},\n            {string_list,[<<\"stop\">>]}},\n {attribute,{key,<<\"gen_ai.usage.input_tokens\">>},{int_value,20}},\n {attribute,{key,<<\"gen_ai.usage.output_tokens\">>},{int_value,7}},\n {attribute,{key,<<\"gen_ai.usage.cache_read.input_tokens\">>},{int_value,6}},\n {attribute,{key,<<\"pig.outcome\">>},{string_value,<<\"succeeded\">>}}]"
        }),
      )
    },
  )
}
