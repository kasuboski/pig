import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import pig_otel
import pig_protocol/inference
import pig_protocol/stop_reason
import pig_proxy/trace_metadata
import pig_transport as transport
import support/tracing_death_harness as death
import support/tracing_harness as check

pub fn buffered_metadata_api_matrix_test() {
  list.each(
    [
      #(
        pig_otel.ChatCompletions,
        "{\"id\":\"r\",\"model\":\"m\",\"choices\":[{\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":3,\"prompt_tokens_details\":{\"cached_tokens\":2}}}",
      ),
      #(
        pig_otel.Responses,
        "{\"id\":\"r\",\"model\":\"m\",\"status\":\"completed\",\"usage\":{\"input_tokens\":9,\"output_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":2}}}",
      ),
    ],
    fn(row) {
      check.check_buffered(
        row.0,
        row.1,
        trace_metadata.Observed(
          inference.InferenceMetadata(
            Some("r"),
            Some("m"),
            Some(stop_reason.Stop),
            Some(9),
            Some(3),
            Some(2),
          ),
          False,
        ),
      )
    },
  )
}

pub fn absent_metadata_is_unknown_not_zero_test() {
  list.each([pig_otel.ChatCompletions, pig_otel.Responses], fn(api) {
    list.each(
      [
        "{}",
        "malformed",
        "{\"usage\":null}",
        "{\"usage\":{\"prompt_tokens\":-9,\"input_tokens\":-9}}",
      ],
      fn(body) { check.check_buffered(api, body, trace_metadata.empty()) },
    )
  })
}

pub fn late_usage_and_trailing_frame_matrix_test() {
  list.each(
    [
      #(pig_otel.ChatCompletions, [
        "data: {\"choices\":[{\"finish_reason\":\"stop\"}]}\n\n",
        "data: {\"usage\":{\"prompt_",
        "tokens\":9,\"completion_tokens\":3}}",
      ]),
      #(pig_otel.Responses, [
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"r\"}}\n\n",
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":9,\"output_tokens\":3}}}",
      ]),
    ],
    fn(row) {
      let metadata =
        inference.InferenceMetadata(
          case row.0 {
            pig_otel.Responses -> Some("r")
            _ -> None
          },
          None,
          Some(stop_reason.Stop),
          Some(9),
          Some(3),
          None,
        )
      check.check_incremental(
        row.0,
        row.1,
        trace_metadata.Observed(metadata, False),
      )
    },
  )
}

pub fn oversized_event_is_skipped_and_late_usage_survives_test() {
  let enormous = "data: {\"PRIVATE_CONTENT\":\"" <> string.repeat("x", 70_000)
  check.check_incremental(
    pig_otel.ChatCompletions,
    [enormous, "\"}\n\n", "data: {\"usage\":{\"prompt_tokens\":0}}\r\n\r\n"],
    trace_metadata.Observed(
      inference.InferenceMetadata(
        ..inference.default_metadata(),
        input_tokens: Some(0),
      ),
      False,
    ),
  )
}

pub fn both_route_sync_retry_and_final_4xx_matrix_test() {
  list.each([pig_otel.ChatCompletions, pig_otel.Responses], fn(api) {
    check.check_sync(
      api,
      [
        transport.Response(500, [], <<>>),
        transport.Response(200, [], bit_array.from_string("{}")),
      ],
      200,
      2,
    )
    check.check_sync(api, [transport.Response(400, [], <<>>)], 400, 1)
  })
}

pub fn both_route_stream_terminal_and_late_duplicate_matrix_test() {
  list.each([pig_otel.ChatCompletions, pig_otel.Responses], fn(api) {
    list.each(
      [check.Complete, check.Fail, check.Crash, check.Duplicate],
      fn(terminal) { check.check_stream(api, terminal) },
    )
  })
}

pub fn metric_labels_are_bounded_without_tracing_test() {
  check.check_labels()
}

pub fn both_route_registered_handoff_and_death_matrix_test() {
  list.each([pig_otel.ChatCompletions, pig_otel.Responses], fn(api) {
    list.each(
      [
        death.BeforeInit,
        death.DuringHandoff,
        death.UpstreamFinishedBeforeHandoff,
        death.AfterAcknowledgement,
        death.ChunkException,
        death.SendFailure,
        death.Cancellation,
        death.Shutdown,
        death.SupervisorShutdown,
      ],
      fn(boundary) { death.check_death(api, boundary) },
    )
  })
}

pub fn real_api_metadata_fixtures_do_not_capture_content_test() {
  let expected =
    trace_metadata.Observed(
      inference.InferenceMetadata(
        Some("r"),
        Some("m"),
        Some(stop_reason.Stop),
        Some(9),
        Some(3),
        Some(2),
      ),
      False,
    )
  list.each(
    [
      #(pig_otel.ChatCompletions, "chat_buffered.json", False),
      #(pig_otel.Responses, "responses_buffered.json", False),
      #(pig_otel.ChatCompletions, "chat_late_usage.sse", True),
      #(pig_otel.Responses, "responses_late_usage.sse", True),
    ],
    fn(row) { check.check_fixture(row.0, row.1, row.2, expected) },
  )
}

pub fn registration_acknowledgement_precedes_span_creation_test() {
  death.check_dormant_registration()
}

pub fn attempts_are_per_io_fallback_and_empty_stream_matrix_test() {
  list.each([pig_otel.ChatCompletions, pig_otel.Responses], fn(api) {
    list.each([False, True], fn(streaming) {
      list.each([False, True], fn(skipped) {
        check.check_attempts(api, streaming, skipped)
      })
    })
  })
}

pub fn model_failure_is_not_success_just_because_http_is_forwardable_test() {
  list.each(
    [
      #(
        pig_otel.ChatCompletions,
        "{\"choices\":[{\"finish_reason\":\"content_filter\"}]}",
      ),
      #(pig_otel.Responses, "{\"status\":\"failed\"}"),
      #(
        pig_otel.Responses,
        "{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"content_filter\"}}",
      ),
    ],
    fn(row) {
      check.check_buffered(
        row.0,
        row.1,
        trace_metadata.Observed(
          inference.InferenceMetadata(
            ..inference.default_metadata(),
            stop_reason: Some(stop_reason.Error),
          ),
          True,
        ),
      )
      check.check_sync(
        row.0,
        [transport.Response(200, [], bit_array.from_string(row.1))],
        200,
        1,
      )
    },
  )
}

pub fn arbitrary_and_oversized_metadata_is_omitted_not_content_captured_test() {
  let enormous = string.repeat("x", 257)
  check.check_buffered(
    pig_otel.ChatCompletions,
    "{\"id\":\""
      <> enormous
      <> "\",\"model\":\""
      <> enormous
      <> "\",\"choices\":[{\"finish_reason\":\"PRIVATE_REASON\"}]}",
    trace_metadata.empty(),
  )
}
