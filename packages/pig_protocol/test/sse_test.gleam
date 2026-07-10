import gleeunit
import gleam/option.{Some}
import pig_protocol/sse
import pig_protocol/stop_reason

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Frame splitting ───────────────────────────────────────────────

pub fn split_frames_separates_two_complete_frames_test() {
  let buffer = "data: one\n\ndata: two\n\n"
  let #(frames, remainder) = sse.split_frames(buffer)
  assert frames == ["data: one", "data: two"]
  assert remainder == ""
}

pub fn split_frames_keeps_partial_frame_as_remainder_test() {
  let buffer = "data: one\n\ndata: partial"
  let #(frames, remainder) = sse.split_frames(buffer)
  assert frames == ["data: one"]
  assert remainder == "data: partial"
}

pub fn frame_data_extracts_single_data_line_test() {
  let data = sse.frame_data("data: {\"hello\": 1}\n\n")
  assert data == "{\"hello\": 1}"
}

pub fn frame_data_joins_multiple_data_lines_test() {
  let data = sse.frame_data("data: line1\ndata: line2\n\n")
  assert data == "line1\nline2"
}

pub fn frame_data_ignores_non_data_lines_test() {
  let data = sse.frame_data("id: 1\nevent: message\ndata: payload\n\n")
  assert data == "payload"
}

// ── Chat Completions stream parsing ───────────────────────────────

pub fn parse_chat_line_content_chunk_test() {
  let data = "{\"choices\": [{\"delta\": {\"content\": \"Hello\"}}]}"
  let assert Ok(sse.ContentChunk("Hello")) = sse.parse_chat_line(data)
}

pub fn parse_chat_line_usage_chunk_test() {
  let data = "{\"choices\": [], \"usage\": {\"prompt_tokens\": 12, \"completion_tokens\": 6}}"
  let assert Ok(sse.UsageChunk(12, 6)) = sse.parse_chat_line(data)
}

pub fn parse_chat_line_done_test() {
  let assert Ok(sse.StreamDone) = sse.parse_chat_line("[DONE]")
}

pub fn parse_chat_line_unknown_returns_error_test() {
  let assert Error(Nil) = sse.parse_chat_line("{\"foo\": 1}")
}

// ── Responses API stream parsing ──────────────────────────────────

pub fn parse_responses_event_output_text_delta_test() {
  let event = sse.parse_responses_event("{\"type\": \"response.output_text.delta\", \"delta\": \"hi\"}")
  assert event == sse.OutputTextDelta("hi")
}

pub fn parse_responses_event_function_call_arguments_delta_test() {
  let event = sse.parse_responses_event("{\"type\": \"response.function_call_arguments.delta\", \"delta\": \"{\\\"a\"}")
  assert event == sse.FunctionCallArgumentsDelta("{\"a")
}

pub fn parse_responses_event_function_call_arguments_done_test() {
  let event = sse.parse_responses_event("{\"type\": \"response.function_call_arguments.done\", \"arguments\": \"{\\\"a\\\": 1}\"}")
  assert event == sse.FunctionCallArgumentsDone("{\"a\": 1}")
}

pub fn parse_responses_event_completed_test() {
  let event = sse.parse_responses_event(
    "{\"type\": \"response.completed\", \"response\": {\"id\": \"r1\", \"model\": \"m\", \"status\": \"completed\", \"usage\": {\"input_tokens\": 1, \"output_tokens\": 2, \"total_tokens\": 3}}}"
  )
  let assert sse.ResponseCompleted(metadata) = event
  let assert Some("r1") = metadata.response_id
  let assert Some("m") = metadata.response_model
  let assert Some(stop_reason.Stop) = metadata.stop_reason
  let assert Some(1) = metadata.input_tokens
  let assert Some(2) = metadata.output_tokens
}

pub fn parse_responses_event_error_test() {
  let event = sse.parse_responses_event("{\"type\": \"error\", \"message\": \"boom\"}")
  assert event == sse.ResponseError("boom")
}

pub fn parse_responses_event_unknown_returns_other_test() {
  let event = sse.parse_responses_event("{\"type\": \"response.created\"}")
  assert event == sse.OtherResponseEvent
}
