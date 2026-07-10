import gleeunit
import pig_protocol/stop_reason

pub fn main() -> Nil {
  gleeunit.main()
}

// ── from_openai mapping ─────────────────────────────────────────────

pub fn from_openai_stop_test() {
  assert stop_reason.from_openai("stop") == stop_reason.Stop
}

pub fn from_openai_tool_calls_test() {
  assert stop_reason.from_openai("tool_calls") == stop_reason.ToolUse
}

pub fn from_openai_length_test() {
  assert stop_reason.from_openai("length") == stop_reason.Length
}

pub fn from_openai_content_filter_test() {
  assert stop_reason.from_openai("content_filter") == stop_reason.Error
}

pub fn from_openai_unknown_test() {
  assert stop_reason.from_openai("new_future_value")
    == stop_reason.Unknown("new_future_value")
}

pub fn from_openai_empty_string_test() {
  assert stop_reason.from_openai("") == stop_reason.Unknown("")
}

// ── to_string ───────────────────────────────────────────────────────

pub fn to_string_stop_test() {
  assert stop_reason.to_string(stop_reason.Stop) == "stop"
}

pub fn to_string_length_test() {
  assert stop_reason.to_string(stop_reason.Length) == "length"
}

pub fn to_string_tool_use_test() {
  assert stop_reason.to_string(stop_reason.ToolUse) == "tool_use"
}

pub fn to_string_error_test() {
  assert stop_reason.to_string(stop_reason.Error) == "error"
}

pub fn to_string_unknown_preserves_value_test() {
  assert stop_reason.to_string(stop_reason.Unknown("custom")) == "custom"
}

// ── from_string ─────────────────────────────────────────────────────

pub fn from_string_stop_test() {
  assert stop_reason.from_string("stop") == stop_reason.Stop
}

pub fn from_string_length_test() {
  assert stop_reason.from_string("length") == stop_reason.Length
}

pub fn from_string_tool_use_test() {
  assert stop_reason.from_string("tool_use") == stop_reason.ToolUse
}

pub fn from_string_error_test() {
  assert stop_reason.from_string("error") == stop_reason.Error
}

pub fn from_string_unknown_test() {
  assert stop_reason.from_string("novel") == stop_reason.Unknown("novel")
}

// ── Round-trip ──────────────────────────────────────────────────────

pub fn to_string_from_string_round_trip_stop_test() {
  assert stop_reason.from_string(stop_reason.to_string(stop_reason.Stop))
    == stop_reason.Stop
}

pub fn to_string_from_string_round_trip_length_test() {
  assert stop_reason.from_string(stop_reason.to_string(stop_reason.Length))
    == stop_reason.Length
}

pub fn to_string_from_string_round_trip_tool_use_test() {
  assert stop_reason.from_string(stop_reason.to_string(stop_reason.ToolUse))
    == stop_reason.ToolUse
}

pub fn to_string_from_string_round_trip_error_test() {
  assert stop_reason.from_string(stop_reason.to_string(stop_reason.Error))
    == stop_reason.Error
}

pub fn to_string_from_string_round_trip_unknown_test() {
  assert stop_reason.from_string(
      stop_reason.to_string(stop_reason.Unknown("x")),
    )
    == stop_reason.Unknown("x")
}

// ── from_openai to_string round-trip ────────────────────────────────

pub fn from_openai_to_string_round_trip_test() {
  // Known OpenAI values round-trip through from_openai → to_string → from_string
  assert stop_reason.from_string(
      stop_reason.to_string(stop_reason.from_openai("stop")),
    )
    == stop_reason.Stop
  assert stop_reason.from_string(
      stop_reason.to_string(stop_reason.from_openai("tool_calls")),
    )
    == stop_reason.ToolUse
  assert stop_reason.from_string(
      stop_reason.to_string(stop_reason.from_openai("length")),
    )
    == stop_reason.Length
}
