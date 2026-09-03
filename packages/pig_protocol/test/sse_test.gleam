import gleam/bit_array
import gleam/list
import gleam/option.{Some}
import gleeunit
import pig_protocol/sse
import pig_protocol/stop_reason
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Byte-safe framing ─────────────────────────────────────────────

type Fixture {
  Fixture(path: String, frames: List(String), data: List(String))
}

pub fn decoder_handles_fixtures_whole_and_at_every_byte_boundary_test() {
  let fixtures = [
    Fixture(
      path: "./test_data/sse/lf_stream.sse",
      frames: [
        ": keep-alive\nevent: message\nx-ignored: yes\ndata: {\"text\":\"hé\"}\ndata: second line",
        "data: [DONE]",
        ":data-only-comment\n",
      ],
      data: ["{\"text\":\"hé\"}\nsecond line", "[DONE]", ""],
    ),
    Fixture(
      path: "./test_data/sse/crlf_stream.sse",
      frames: [
        ": keep-alive\r\nevent: message\r\nunknown: ignored\r\ndata: first\r\ndata: second",
        "data: café\r\n",
      ],
      data: ["first\nsecond", "café"],
    ),
    Fixture(
      path: "./test_data/sse/mixed_stream.sse",
      frames: [
        ": heartbeat\rdata:  first  \ndata:\tsecond",
        "data:third\rdata: fourth",
        "data: final\n",
      ],
      data: [" first  \n\tsecond", "third\nfourth", "final"],
    ),
  ]

  list.each(fixtures, assert_fixture)
}

pub fn decoder_handles_one_byte_chunks_test() {
  let fixture = read_fixture("./test_data/sse/crlf_stream.sse")
  let bits = bit_array.from_string(fixture)
  let chunks = one_byte_chunks(bits, 0, bit_array.byte_size(bits), [])
  let assert [first, second] = decode_chunks(chunks)
  assert sse.frame_data(first) == "first\nsecond"
  assert sse.frame_data(second) == "café"
}

pub fn decoder_rejects_invalid_utf8_in_complete_frame_test() {
  let invalid_frame: BitArray = <<100, 97, 116, 97, 58, 32, 255, 10, 10>>
  let assert Error(sse.InvalidUtf8) = sse.push(sse.new(), invalid_frame)
}

pub fn decoder_rejects_invalid_utf8_at_end_of_stream_test() {
  let invalid_frame: BitArray = <<100, 97, 116, 97, 58, 32, 255>>
  let assert Ok(#(decoder, [])) = sse.push(sse.new(), invalid_frame)
  let assert Error(sse.InvalidUtf8) = sse.finish(decoder)
}

fn assert_fixture(fixture: Fixture) -> Nil {
  let bits = bit_array.from_string(read_fixture(fixture.path))
  let byte_size = bit_array.byte_size(bits)
  assert decode_chunks([bits]) == fixture.frames
  assert_boundaries(bits, byte_size, 0, fixture.frames)
  assert list.map(fixture.frames, sse.frame_data) == fixture.data
}

fn assert_boundaries(
  bits: BitArray,
  byte_size: Int,
  boundary: Int,
  expected: List(String),
) -> Nil {
  case boundary > byte_size {
    True -> Nil
    False -> {
      let assert Ok(prefix) = bit_array.slice(bits, 0, boundary)
      let assert Ok(suffix) =
        bit_array.slice(bits, boundary, byte_size - boundary)
      assert decode_chunks([prefix, suffix]) == expected
      assert_boundaries(bits, byte_size, boundary + 1, expected)
    }
  }
}

fn decode_chunks(chunks: List(BitArray)) -> List(String) {
  let #(decoder, frames) =
    list.fold(chunks, #(sse.new(), []), fn(state, chunk) {
      let assert Ok(#(decoder, new_frames)) = sse.push(state.0, chunk)
      #(decoder, list.append(state.1, new_frames))
    })
  let assert Ok(final_frames) = sse.finish(decoder)
  list.append(frames, final_frames)
}

fn one_byte_chunks(
  bits: BitArray,
  offset: Int,
  byte_size: Int,
  chunks: List(BitArray),
) -> List(BitArray) {
  case offset >= byte_size {
    True -> list.reverse(chunks)
    False -> {
      let assert Ok(chunk) = bit_array.slice(bits, offset, 1)
      one_byte_chunks(bits, offset + 1, byte_size, [chunk, ..chunks])
    }
  }
}

fn read_fixture(path: String) -> String {
  let assert Ok(fixture) = simplifile.read(path)
  fixture
}

// ── Compatibility framing helpers ────────────────────────────────

pub fn split_frames_separates_two_complete_frames_test() {
  let buffer = "data: one\n\ndata: two\n\n"
  let #(frames, remainder) = sse.split_frames(buffer)
  assert frames == ["data: one", "data: two"]
  assert remainder == ""
}

pub fn split_frames_handles_mixed_line_endings_test() {
  let buffer = "data: one\r\ndata: two\n\ndata: three\r\rpartial"
  let #(frames, remainder) = sse.split_frames(buffer)
  assert frames == ["data: one\r\ndata: two", "data: three"]
  assert remainder == "partial"
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

pub fn frame_data_preserves_payload_whitespace_test() {
  let data = sse.frame_data("data:  leading  \rdata:\ttrailing\r\n")
  assert data == " leading  \n\ttrailing"
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
  let data =
    "{\"choices\": [], \"usage\": {\"prompt_tokens\": 12, \"completion_tokens\": 6}}"
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
  let event =
    sse.parse_responses_event(
      "{\"type\": \"response.output_text.delta\", \"delta\": \"hi\"}",
    )
  assert event == sse.OutputTextDelta("hi")
}

pub fn parse_responses_event_function_call_arguments_delta_test() {
  let event =
    sse.parse_responses_event(
      "{\"type\": \"response.function_call_arguments.delta\", \"delta\": \"{\\\"a\"}",
    )
  assert event == sse.FunctionCallArgumentsDelta("{\"a")
}

pub fn parse_responses_event_function_call_arguments_done_test() {
  let event =
    sse.parse_responses_event(
      "{\"type\": \"response.function_call_arguments.done\", \"arguments\": \"{\\\"a\\\": 1}\"}",
    )
  assert event == sse.FunctionCallArgumentsDone("{\"a\": 1}")
}

pub fn parse_responses_event_completed_test() {
  let event =
    sse.parse_responses_event(
      "{\"type\": \"response.completed\", \"response\": {\"id\": \"r1\", \"model\": \"m\", \"status\": \"completed\", \"usage\": {\"input_tokens\": 1, \"output_tokens\": 2, \"total_tokens\": 3, \"input_tokens_details\": {\"cached_tokens\": 1}}}}",
    )
  let assert sse.ResponseCompleted(metadata) = event
  let assert Some("r1") = metadata.response_id
  let assert Some("m") = metadata.response_model
  let assert Some(stop_reason.Stop) = metadata.stop_reason
  let assert Some(1) = metadata.input_tokens
  let assert Some(2) = metadata.output_tokens
  let assert Some(1) = metadata.cached_input_tokens
}

pub fn parse_responses_event_error_test() {
  let event =
    sse.parse_responses_event("{\"type\": \"error\", \"message\": \"boom\"}")
  assert event == sse.ResponseError("boom")
}

pub fn parse_responses_event_unknown_returns_other_test() {
  // Use a type that the parser doesn't recognize (note: `response.created`
  // and `response.completed` *are* recognized — see `responses_event_decoder`).
  let event =
    sse.parse_responses_event(
      "{\"type\": \"response.audio.delta\", \"delta\": \"x\"}",
    )
  assert event == sse.OtherResponseEvent
}
