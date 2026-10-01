//// Externalized schema-projection and bounded streaming regression cases.

import support/content_harness as content

pub fn content_typed_shape_validation_test() {
  content.check_shapes()
}

pub fn options_validation_test() {
  content.check_options()
}

pub fn input_chat_structured_test() {
  content.check_content("input_chat_structured")
}

pub fn input_responses_ordered_test() {
  content.check_content("input_responses_ordered")
}

pub fn input_responses_native_media_test() {
  content.check_content("input_responses_native_media")
  content.check_content("input_responses_native_media_streaming")
  content.check_content("input_responses_native_text")
  content.check_content("input_responses_native_unknown")
  content.check_content("input_responses_native_text_redacted")
  content.check_content("input_responses_application_array")
}

pub fn input_responses_string_test() {
  content.check_content("input_responses_string")
}

pub fn input_empty_test() {
  content.check_content("input_empty")
}

pub fn input_unknown_only_test() {
  content.check_content("input_unknown_only")
}

pub fn output_chat_choices_test() {
  content.check_content("output_chat_choices")
}

pub fn output_responses_parts_test() {
  content.check_content("output_responses_parts")
}

pub fn output_responses_failed_test() {
  content.check_content("output_responses_failed")
}

pub fn output_responses_incomplete_test() {
  content.check_content("output_responses_incomplete")
}

pub fn output_responses_cancelled_test() {
  content.check_content("output_responses_cancelled")
}

pub fn output_responses_empty_test() {
  content.check_content("output_responses_empty")
}

pub fn output_missing_finish_test() {
  content.check_content("output_missing_finish")
}

pub fn output_unknown_finish_test() {
  content.check_content("output_unknown_finish")
}

pub fn output_error_envelope_test() {
  content.check_content("output_error_envelope")
}

pub fn input_malformed_arguments_test() {
  content.check_content("input_malformed_arguments")
}

pub fn input_malformed_json_result_test() {
  content.check_content("input_malformed_json_result")
}

pub fn input_plain_result_test() {
  content.check_content("input_plain_result")
}

pub fn input_blocked_identity_test() {
  content.check_content("input_blocked_identity")
}

pub fn input_unknown_api_test() {
  content.check_content("input_unknown_api")
}

pub fn input_invalid_utf8_test() {
  content.check_content("input_invalid_utf8")
}

pub fn input_invalid_json_test() {
  content.check_content("input_invalid_json")
}

pub fn input_source_limit_test() {
  content.check_content("input_source_limit")
}

pub fn input_escape_budget_test() {
  content.check_content("input_escape_budget")
}

pub fn input_redaction_expansion_test() {
  content.check_content("input_redaction_expansion")
}

pub fn input_depth_limit_test() {
  content.check_content("input_depth_limit")
}

pub fn input_node_limit_test() {
  content.check_content("input_node_limit")
}

pub fn input_message_limit_test() {
  content.check_content("input_message_limit")
}

pub fn input_part_limit_test() {
  content.check_content("input_part_limit")
}

pub fn input_tool_limit_test() {
  content.check_content("input_tool_limit")
}

pub fn output_candidate_limit_test() {
  content.check_content("output_candidate_limit")
}

pub fn stream_chat_choices_test() {
  content.check_stream("stream_chat_choices")
}

pub fn stream_chat_identity_fragments_test() {
  content.check_stream("stream_chat_protocol_fragments")
  content.check_stream("stream_chat_repeated_identity")
  content.check_stream("stream_chat_identity_256")
  content.check_stream("stream_chat_identity_utf8_256")
  content.check_stream("stream_chat_id_257")
  content.check_stream("stream_chat_name_257")
  content.check_stream("stream_chat_identity_utf8_257")
  content.check_stream("stream_chat_id_literal_fragments")
  content.check_stream("stream_chat_name_literal_fragments")
  content.check_stream("stream_chat_identity_url_fragments")
}

pub fn stream_chat_terminal_sentinel_bounds_test() {
  content.check_stream("stream_chat_protocol_incomplete_owner")
  content.check_stream("stream_chat_protocol_unterminated_sentinel")
  content.check_stream("stream_chat_protocol_extra_data")
  content.check_stream("stream_chat_trailing_json_frame")
}

pub fn stream_responses_immutable_identity_test() {
  content.check_stream("stream_responses_immutable_item")
  content.check_stream("stream_responses_immutable_call")
}

pub fn stream_chat_source_done_without_sentinel_test() {
  content.check_stream("stream_chat_source_done_without_sentinel")
}

pub fn stream_chat_multiline_test() {
  content.check_stream("stream_chat_multiline")
}

pub fn stream_chat_incomplete_owner_test() {
  content.check_stream("stream_chat_incomplete_owner")
}

pub fn stream_chat_unfinished_done_test() {
  content.check_stream("stream_chat_unfinished_done")
}

pub fn stream_chat_partial_frame_test() {
  content.check_stream("stream_chat_partial_frame")
}

pub fn stream_chat_partial_line_test() {
  content.check_stream("stream_chat_partial_line")
}

pub fn stream_chat_malformed_after_finish_test() {
  content.check_stream("stream_chat_malformed_after_finish")
}

pub fn stream_chat_error_after_finish_test() {
  content.check_stream("stream_chat_error_after_finish")
}

pub fn stream_chat_oversize_frame_test() {
  content.check_stream("stream_chat_oversize_frame")
}

pub fn stream_chat_exhausted_test() {
  content.check_stream("stream_chat_exhausted")
}

pub fn stream_chat_empty_test() {
  content.check_stream("stream_chat_empty")
}

pub fn stream_chat_bad_index_test() {
  content.check_stream("stream_chat_bad_index")
}

pub fn stream_chat_bad_tool_json_test() {
  content.check_stream("stream_chat_bad_tool_json")
}

pub fn stream_chat_bad_utf8_test() {
  content.check_stream("stream_chat_bad_utf8")
}

pub fn stream_responses_final_replacement_test() {
  content.check_stream("stream_responses_final_replacement")
}

pub fn stream_responses_missing_final_output_test() {
  content.check_stream("stream_responses_missing_final_output")
}

pub fn stream_responses_explicit_empty_test() {
  content.check_stream("stream_responses_explicit_empty")
}

pub fn stream_responses_missing_item_done_test() {
  content.check_stream("stream_responses_missing_item_done")
}

pub fn stream_responses_missing_terminal_test() {
  content.check_stream("stream_responses_missing_terminal")
}

pub fn stream_responses_missing_all_output_test() {
  content.check_stream("stream_responses_missing_all_output")
}

pub fn stream_responses_failed_test() {
  content.check_stream("stream_responses_failed")
}

pub fn stream_responses_incomplete_test() {
  content.check_stream("stream_responses_incomplete")
}

pub fn stream_responses_cancelled_test() {
  content.check_stream("stream_responses_cancelled")
}

pub fn stream_responses_failed_after_complete_test() {
  content.check_stream("stream_responses_failed_after_complete")
}

pub fn stream_responses_unfinished_final_test() {
  content.check_stream("stream_responses_unfinished_final")
}

pub fn stream_responses_tools_ordered_test() {
  content.check_stream("stream_responses_tools_ordered")
}

pub fn stream_responses_unknown_parts_test() {
  content.check_stream("stream_responses_unknown_parts")
}

pub fn stream_responses_item_mismatch_test() {
  content.check_stream("stream_responses_item_mismatch")
}

pub fn stream_content_budget_test() {
  content.check_stream("stream_content_budget")
}

pub fn stream_chat_tool_only_test() {
  content.check_stream("stream_chat_tool_only")
}

pub fn input_array_payloads_test() {
  content.check_content("input_array_payloads")
}

pub fn input_literal_overlap_test() {
  content.check_content("input_literal_overlap")
}

pub fn output_chat_filtered_parts_test() {
  content.check_content("output_chat_filtered_parts")
}

pub fn stream_responses_full_only_test() {
  content.check_stream("stream_responses_full_only")
}

pub fn stream_responses_full_replaces_deltas_test() {
  content.check_stream("stream_responses_full_replaces_deltas")
}

pub fn stream_chat_retained_line_test() {
  content.check_stream("stream_chat_retained_line")
}

pub fn stream_depth_limit_test() {
  content.check_stream("stream_depth_limit")
}

pub fn stream_node_limit_test() {
  content.check_stream("stream_node_limit")
}

pub fn stream_chat_choice_limit_test() {
  content.check_stream("stream_chat_choice_limit")
}

pub fn stream_responses_part_limit_test() {
  content.check_stream("stream_responses_part_limit")
}

pub fn input_combined_budget_test() {
  content.check_content("input_combined_budget")
}

pub fn input_binary_non_json_test() {
  content.check_content("input_binary_non_json")
}

pub fn input_no_messages_test() {
  content.check_content("input_no_messages")
}

pub fn stream_done_only_test() {
  content.check_stream("stream_done_only")
}

pub fn stream_usage_only_test() {
  content.check_stream("stream_usage_only")
}

pub fn stream_frame_after_done_test() {
  content.check_stream("stream_frame_after_done")
}

pub fn stream_chat_cr_framing_test() {
  content.check_stream("stream_chat_cr_framing")
}

pub fn input_numeric_token_limit_test() {
  content.check_content("input_numeric_token_limit")
}

pub fn input_unknown_tool_call_test() {
  content.check_content("input_unknown_tool_call")
}

pub fn input_blocked_tool_name_test() {
  content.check_content("input_blocked_tool_name")
}

pub fn input_json_string_within_string_test() {
  content.check_content("input_json_string_within_string")
}

pub fn input_extensions_keep_defaults_test() {
  content.check_content("input_extensions_keep_defaults")
}

pub fn output_chat_empty_test() {
  content.check_content("output_chat_empty")
}

pub fn stream_incomplete_overrides_overflow_test() {
  content.check_stream("stream_incomplete_overrides_overflow")
}
