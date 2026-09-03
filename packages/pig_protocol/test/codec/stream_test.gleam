import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import pig_protocol/codec/chat
import pig_protocol/codec/chat_stream
import pig_protocol/codec/responses
import pig_protocol/codec/responses_stream
import pig_protocol/error
import pig_protocol/inference
import pig_protocol/message
import pig_protocol/sse
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn chat_stream_matches_buffered_fixture_test() {
  let #(accumulator, deltas) =
    accumulate_chat("./test_data/streams/chat_stream.sse")
  let assert Ok(streamed) = chat_stream.finish(accumulator)
  let assert Ok(buffered) =
    chat.parse_response(read_fixture("./test_data/streams/chat_buffered.json"))
  assert streamed == buffered
  assert deltas
    == [
      inference.TextDelta("Hel"),
      inference.TextDelta("lo "),
      inference.ReasoningDelta("think"),
      inference.ReasoningDelta("ing"),
      inference.ToolCallStarted(0, "call_", "wea"),
      inference.ToolArgumentDelta(0, "{\"city\":\""),
      inference.ToolArgumentDelta(0, "Berlin\"}"),
      inference.ToolCallStarted(1, "call_2", "calc"),
      inference.ToolArgumentDelta(1, "{\"x\":"),
      inference.ToolArgumentDelta(1, "2}"),
    ]
}

pub fn chat_stream_without_finish_reason_matches_buffered_fixture_test() {
  let #(accumulator, _) =
    accumulate_chat("./test_data/streams/chat_stream_no_finish.sse")
  let assert Ok(streamed) = chat_stream.finish(accumulator)
  let assert Ok(buffered) =
    chat.parse_response(read_fixture(
      "./test_data/streams/chat_buffered_no_finish.json",
    ))
  assert streamed == buffered
  let assert message.Assistant(stop_reason: None, ..) = streamed.message
  assert streamed.metadata.stop_reason == None
}

pub fn responses_stream_matches_buffered_fixture_test() {
  let #(accumulator, deltas) =
    accumulate_responses("./test_data/streams/responses_stream.sse")
  let assert Ok(streamed) = responses_stream.finish(accumulator)
  let assert Ok(buffered) =
    responses.parse_response(read_fixture(
      "./test_data/streams/responses_buffered.json",
    ))
  assert streamed == buffered
  assert deltas
    == [
      inference.ReasoningDelta("Plan"),
      inference.ReasoningDelta("\n\n"),
      inference.ReasoningDelta("details"),
      inference.TextDelta("Hello"),
      inference.TextDelta("?"),
      inference.ToolCallStarted(2, "call_1", "lookup"),
      inference.ToolArgumentDelta(2, "{\"x\""),
      inference.ToolArgumentDelta(2, ":1}"),
    ]
}

pub fn responses_incomplete_function_call_stream_matches_buffered_fixture_test() {
  let #(accumulator, _) =
    accumulate_responses(
      "./test_data/streams/responses_stream_incomplete_tool.sse",
    )
  let assert Ok(streamed) = responses_stream.finish(accumulator)
  let assert Ok(buffered) =
    responses.parse_response(read_fixture(
      "./test_data/streams/responses_buffered_incomplete_tool.json",
    ))
  assert streamed == buffered
}

pub fn chat_stream_builders_enable_usage_and_streaming_test() {
  let body =
    chat.build_stream_request_body([message.User("hello")], [], "gpt-4o")
  let assert Ok(True) = json.parse(body, decode.at(["stream"], decode.bool))
  let assert Ok(True) =
    json.parse(
      body,
      decode.at(["stream_options", "include_usage"], decode.bool),
    )
  let buffered = chat.build_request_body([message.User("hello")], [], "gpt-4o")
  let assert Ok(False) =
    json.parse(buffered, decode.at(["stream"], decode.bool))
  let assert Error(_) =
    json.parse(
      buffered,
      decode.at(["stream_options", "include_usage"], decode.bool),
    )
}

pub fn responses_stream_builder_enables_streaming_test() {
  let body =
    responses.build_stream_request_body(
      [message.User("hello")],
      [],
      "gpt-5",
      None,
    )
  let assert Ok(True) = json.parse(body, decode.at(["stream"], decode.bool))
  let buffered =
    responses.build_request_body([message.User("hello")], [], "gpt-5", None)
  let assert Ok(False) =
    json.parse(buffered, decode.at(["stream"], decode.bool))
}

pub fn chat_stream_reports_api_errors_and_malformed_events_test() {
  let assert Error(error.ApiError("quota exceeded")) =
    chat_stream.push(
      chat_stream.new(),
      "{\"error\":{\"message\":\"quota exceeded\"}}",
    )
  let assert Error(error.InvalidResponse(_)) =
    chat_stream.push(chat_stream.new(), "not json")
}

pub fn chat_stream_reports_early_eof_test() {
  let assert Error(error.InvalidResponse(detail)) =
    chat_stream.finish(chat_stream.new())
  assert detail == "Stream ended before [DONE]"
}

pub fn responses_stream_reports_terminal_errors_and_early_eof_test() {
  let assert Error(error.ApiError("backend failed")) =
    responses_stream.push(
      responses_stream.new(),
      "{\"type\":\"response.failed\",\"response\":{\"error\":{\"message\":\"backend failed\"}}}",
    )
  let assert Error(error.InvalidResponse(_)) =
    responses_stream.finish(responses_stream.new())
}

pub fn chat_stream_captures_cached_input_tokens_test() {
  let #(accumulator, _) = accumulate_chat("./test_data/streams/chat_stream.sse")
  let assert Ok(result) = chat_stream.finish(accumulator)
  let assert Some(12) = result.metadata.input_tokens
  let assert Some(8) = result.metadata.cached_input_tokens
}

pub fn responses_stream_captures_cached_input_tokens_test() {
  let #(accumulator, _) =
    accumulate_responses("./test_data/streams/responses_stream.sse")
  let assert Ok(result) = responses_stream.finish(accumulator)
  let assert Some(15) = result.metadata.input_tokens
  let assert Some(10) = result.metadata.cached_input_tokens
}

fn accumulate_chat(
  path: String,
) -> #(chat_stream.Accumulator, List(inference.InferenceDelta)) {
  accumulate_chat_payloads(payloads(path), chat_stream.new(), [])
}

fn accumulate_chat_payloads(
  values: List(String),
  accumulator: chat_stream.Accumulator,
  deltas: List(inference.InferenceDelta),
) -> #(chat_stream.Accumulator, List(inference.InferenceDelta)) {
  case values {
    [] -> #(accumulator, deltas)
    [value, ..rest] -> {
      let assert Ok(#(next, new_deltas)) = chat_stream.push(accumulator, value)
      accumulate_chat_payloads(rest, next, list.append(deltas, new_deltas))
    }
  }
}

fn accumulate_responses(
  path: String,
) -> #(responses_stream.Accumulator, List(inference.InferenceDelta)) {
  accumulate_response_payloads(payloads(path), responses_stream.new(), [])
}

fn accumulate_response_payloads(
  values: List(String),
  accumulator: responses_stream.Accumulator,
  deltas: List(inference.InferenceDelta),
) -> #(responses_stream.Accumulator, List(inference.InferenceDelta)) {
  case values {
    [] -> #(accumulator, deltas)
    [value, ..rest] -> {
      let assert Ok(#(next, new_deltas)) =
        responses_stream.push(accumulator, value)
      accumulate_response_payloads(rest, next, list.append(deltas, new_deltas))
    }
  }
}

fn payloads(path: String) -> List(String) {
  let #(frames, remainder) = sse.split_frames(read_fixture(path))
  let frames = case remainder {
    "" -> frames
    frame -> list.append(frames, [frame])
  }
  list.map(frames, sse.frame_data)
}

fn read_fixture(path: String) -> String {
  let assert Ok(content) = simplifile.read(path)
  content
}
