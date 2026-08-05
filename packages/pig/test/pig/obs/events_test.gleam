import gleam/dict
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import pig/obs/dispatcher
import pig/obs/emit
import pig/obs/events.{InferenceStarted, NormalEnd, SessionEnded, SessionStarted}
import pig/obs/listener
import pig/provider
import pig_protocol/stop_reason
import pig_protocol/thinking

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Event Name Constraints ───────────────────────────────────────────
// We don't assert exact literals — that just echoes the implementation.
// Instead we test structural invariants that must hold regardless of
// what specific names we choose.

/// All event names live under the "pig" namespace.
pub fn all_names_start_with_pig_test() {
  let all_ok =
    events.all_event_names()
    |> list.all(fn(name) {
      case name {
        ["pig", ..] -> True
        _ -> False
      }
    })
  assert all_ok
}

/// Every event name has exactly 3 segments (namespace, domain, action).
pub fn all_names_have_three_segments_test() {
  let all_ok =
    events.all_event_names()
    |> list.all(fn(name) { list.length(name) == 3 })
  assert all_ok
}

/// No duplicate event names.
pub fn all_event_names_unique_test() {
  let names = events.all_event_names()
  assert list.length(names) == list.length(list.unique(names))
}

/// event_name() returns the same value as the corresponding name function.
pub fn event_name_matches_inference_start_test() {
  assert events.event_name(events.InferenceStart(
      model: "x",
      message_count: 0,
      settings: provider.default_settings(),
    ))
    == events.inference_start_name()
}

pub fn event_name_matches_inference_stop_test() {
  assert events.event_name(events.InferenceStop(
      model: "x",
      message_count: 0,
      duration_ms: 0,
      response_id: None,
      stop_reason: None,
      input_tokens: None,
      output_tokens: None,
      settings: provider.default_settings(),
    ))
    == events.inference_stop_name()
}

pub fn event_name_matches_tool_start_test() {
  assert events.event_name(events.ToolStart(
      tool_name: "x",
      tool_call_id: "y",
      arguments_json: "{}",
    ))
    == events.tool_start_name()
}

// ── name_to_string ───────────────────────────────────────────────────

/// name_to_string join segments with dots.
pub fn name_to_string_joins_with_dots_test() {
  assert events.name_to_string(["a", "b", "c"]) == "a.b.c"
}

pub fn name_to_string_single_segment_test() {
  assert events.name_to_string(["pig"]) == "pig"
}

pub fn name_to_string_empty_test() {
  assert events.name_to_string([]) == ""
}

pub fn settings_use_provider_neutral_strings_test() {
  assert events.settings_to_string(provider.default_settings())
    == "provider_default"
  assert events.settings_to_string(provider.with_thinking_level(thinking.Off))
    == "off"
  assert events.settings_to_string(provider.with_thinking_level(thinking.High))
    == "high"
}

pub fn settings_parse_rejects_unknown_values_test() {
  assert
    events.settings_from_string("provider_default")
    == Ok(provider.default_settings())
  assert events.settings_from_string("none") == Error(Nil)
  assert events.settings_from_string("not-a-level") == Error(Nil)
}

// ── Event Equality ───────────────────────────────────────────────────
// Structural equality is a property worth testing — it means events
// can be used in assertions and dict keys.

pub fn same_event_is_equal_test() {
  let e1 =
    events.InferenceStart(
      model: "a",
      message_count: 1,
      settings: provider.default_settings(),
    )
  let e2 =
    events.InferenceStart(
      model: "a",
      message_count: 1,
      settings: provider.default_settings(),
    )
  assert e1 == e2
}

pub fn different_fields_not_equal_test() {
  let e1 =
    events.InferenceStart(
      model: "a",
      message_count: 1,
      settings: provider.default_settings(),
    )
  let e2 =
    events.InferenceStart(
      model: "b",
      message_count: 1,
      settings: provider.default_settings(),
    )
  assert e1 != e2
}

pub fn different_variants_not_equal_test() {
  let e1 =
    events.InferenceStart(
      model: "a",
      message_count: 1,
      settings: provider.default_settings(),
    )
  let e2 =
    events.ToolStart(tool_name: "a", tool_call_id: "1", arguments_json: "{}")
  assert e1 != e2
}

// ── emit Does Not Crash ──────────────────────────────────────────────
// Each variant must be emittable without error. Tests real :telemetry integration.

pub fn emit_all_variants_test() {
  events.emit(events.InferenceStart(
    model: "gpt-4",
    message_count: 5,
    settings: provider.default_settings(),
  ))
  events.emit(events.InferenceStop(
    model: "gpt-4",
    message_count: 5,
    duration_ms: 150,
    response_id: None,
    stop_reason: None,
    input_tokens: None,
    output_tokens: None,
    settings: provider.default_settings(),
  ))
  events.emit(events.InferenceException(
    model: "gpt-4",
    message_count: 3,
    error_type: "test_error",
    settings: provider.default_settings(),
  ))
  events.emit(events.ToolStart(
    tool_name: "read_file",
    tool_call_id: "call_123",
    arguments_json: "{}",
  ))
  events.emit(events.ToolStop(
    tool_name: "read_file",
    tool_call_id: "call_123",
    duration_ms: 42,
    result: "{\"files\":[]}",
  ))
  events.emit(events.ToolException(
    tool_name: "bash",
    tool_call_id: "call_456",
    arguments_json: "{}",
  ))
  Nil
}

// ── Generic Emit Helpers ─────────────────────────────────────────────

pub fn generic_emit_start_does_not_crash_test() {
  let meta = dict.from_list([#("custom_key", "custom_value")])
  events.emit_start(["pig", "custom", "start"], meta)
  Nil
}

pub fn generic_emit_stop_does_not_crash_test() {
  let meta = dict.from_list([#("custom_key", "custom_value")])
  events.emit_stop(["pig", "custom", "stop"], 100, meta)
  Nil
}

pub fn generic_emit_exception_does_not_crash_test() {
  let meta = dict.from_list([#("custom_key", "custom_value")])
  events.emit_exception(["pig", "custom", "exception"], meta)
  Nil
}

// ── Decode Round-Trip ────────────────────────────────────────────────
// Decode is a real transformation (raw dict → typed Event).
// Test that emit → capture → decode preserves the original event data.
// We verify field preservation, not exact struct equality.

pub fn decode_preserves_non_default_inference_settings_test() {
  let raw =
    events.RawCapturedEvent(
      name: events.inference_start_name(),
      measurements: dict.from_list([#("message_count", 5)]),
      metadata: dict.from_list([#("model", "gpt-4"), #("thinking", "off")]),
    )
  let assert events.InferenceStart(settings:, ..) = events.decode(raw)
  assert settings == provider.with_thinking_level(thinking.Off)
}

pub fn decode_preserves_inference_start_test() {
  let raw =
    events.RawCapturedEvent(
      name: events.inference_start_name(),
      measurements: dict.from_list([
        #("system_time", 123),
        #("message_count", 5),
      ]),
      metadata: dict.from_list([#("model", "gpt-4")]),
    )
  let assert events.InferenceStart(model:, message_count:, settings: _) =
    events.decode(raw)
  assert model == "gpt-4"
  assert message_count == 5
}

pub fn decode_preserves_inference_stop_test() {
  let raw =
    events.RawCapturedEvent(
      name: events.inference_stop_name(),
      measurements: dict.from_list([
        #("system_time", 456),
        #("message_count", 2),
        #("duration", 150),
      ]),
      metadata: dict.from_list([#("model", "gpt-4")]),
    )
  let assert events.InferenceStop(
    model:,
    message_count:,
    duration_ms:,
    response_id:,
    stop_reason:,
    input_tokens:,
    output_tokens:,
    settings: _,
  ) = events.decode(raw)
  assert model == "gpt-4"
  assert message_count == 2
  assert duration_ms == 150
  assert response_id == None
  assert stop_reason == None
  assert input_tokens == None
  assert output_tokens == None
}

pub fn decode_preserves_tool_start_test() {
  let raw =
    events.RawCapturedEvent(
      name: events.tool_start_name(),
      measurements: dict.from_list([#("system_time", 789)]),
      metadata: dict.from_list([
        #("tool_name", "bash"),
        #("tool_call_id", "c1"),
        #("arguments_json", "{\"foo\":\"bar\"}"),
      ]),
    )
  let assert events.ToolStart(tool_name:, tool_call_id:, arguments_json:) =
    events.decode(raw)
  assert tool_name == "bash"
  assert tool_call_id == "c1"
  assert arguments_json == "{\"foo\":\"bar\"}"
}

pub fn decode_preserves_tool_stop_test() {
  let raw =
    events.RawCapturedEvent(
      name: events.tool_stop_name(),
      measurements: dict.from_list([#("system_time", 999), #("duration", 42)]),
      metadata: dict.from_list([
        #("tool_name", "bash"),
        #("tool_call_id", "c1"),
        #("result", "{\"foo\":\"bar\"}"),
      ]),
    )
  let assert events.ToolStop(tool_name:, tool_call_id:, duration_ms:, result:) =
    events.decode(raw)
  assert tool_name == "bash"
  assert tool_call_id == "c1"
  assert duration_ms == 42
  assert result == "{\"foo\":\"bar\"}"
}

pub fn decode_preserves_tool_exception_test() {
  let raw =
    events.RawCapturedEvent(
      name: events.tool_exception_name(),
      measurements: dict.from_list([#("system_time", 999)]),
      metadata: dict.from_list([
        #("tool_name", "bash"),
        #("tool_call_id", "c1"),
        #("arguments_json", "{\"foo\":\"bar\"}"),
      ]),
    )
  let assert events.ToolException(tool_name:, tool_call_id:, arguments_json:) =
    events.decode(raw)
  assert tool_name == "bash"
  assert tool_call_id == "c1"
  assert arguments_json == "{\"foo\":\"bar\"}"
}

pub fn decode_preserves_inference_exception_test() {
  let raw =
    events.RawCapturedEvent(
      name: events.inference_exception_name(),
      measurements: dict.from_list([
        #("system_time", 999),
        #("message_count", 7),
      ]),
      metadata: dict.from_list([#("model", "llama"), #("error_type", "timeout")]),
    )
  let assert events.InferenceException(
    model:,
    message_count:,
    error_type:,
    settings: _,
  ) = events.decode(raw)
  assert model == "llama"
  assert message_count == 7
  assert error_type == "timeout"
}

// ── Task 9.0e: Enriched InferenceStop Tests ─────────────────────────────

/// Emit InferenceStop with all new fields populated — should not crash.
pub fn emit_enriched_inference_stop_does_not_crash_test() {
  events.emit(events.InferenceStop(
    model: "gpt-4",
    message_count: 5,
    duration_ms: 150,
    response_id: Some("resp-123"),
    stop_reason: Some(stop_reason.Stop),
    input_tokens: Some(100),
    output_tokens: Some(50),
    settings: provider.default_settings(),
  ))
  Nil
}

/// Decode InferenceStop with all new fields in the raw data.
pub fn decode_preserves_enriched_inference_stop_test() {
  let raw =
    events.RawCapturedEvent(
      name: events.inference_stop_name(),
      measurements: dict.from_list([
        #("system_time", 456),
        #("message_count", 2),
        #("duration", 150),
        #("input_tokens", 100),
        #("output_tokens", 50),
      ]),
      metadata: dict.from_list([
        #("model", "gpt-4"),
        #("response_id", "resp-456"),
        #("stop_reason", "stop"),
      ]),
    )
  let assert events.InferenceStop(
    model:,
    message_count:,
    duration_ms:,
    response_id:,
    stop_reason:,
    input_tokens:,
    output_tokens:,
    settings: _,
  ) = events.decode(raw)
  assert model == "gpt-4"
  assert message_count == 2
  assert duration_ms == 150
  assert response_id == Some("resp-456")
  assert stop_reason == Some(stop_reason.Stop)
  assert input_tokens == Some(100)
  assert output_tokens == Some(50)
}

/// Decode InferenceStop without optional fields — should decode to None.
pub fn decode_enriched_inference_stop_handles_missing_optional_fields_test() {
  let raw =
    events.RawCapturedEvent(
      name: events.inference_stop_name(),
      measurements: dict.from_list([
        #("system_time", 456),
        #("message_count", 2),
        #("duration", 150),
      ]),
      metadata: dict.from_list([#("model", "gpt-4")]),
    )
  let assert events.InferenceStop(
    model:,
    message_count:,
    duration_ms:,
    response_id:,
    stop_reason:,
    input_tokens:,
    output_tokens:,
    settings: _,
  ) = events.decode(raw)
  assert model == "gpt-4"
  assert message_count == 2
  assert duration_ms == 150
  assert response_id == None
  assert stop_reason == None
  assert input_tokens == None
  assert output_tokens == None
}

// ── Task 9.0e: InferenceException with error_type Tests ─────────────────

/// Emit InferenceException with error_type — should not crash.
pub fn emit_inference_exception_with_error_type_test() {
  events.emit(events.InferenceException(
    model: "gpt-4",
    message_count: 3,
    error_type: "timeout",
    settings: provider.default_settings(),
  ))
  Nil
}

/// Decode InferenceException preserves error_type from metadata.
pub fn decode_preserves_inference_exception_error_type_test() {
  let raw =
    events.RawCapturedEvent(
      name: events.inference_exception_name(),
      measurements: dict.from_list([
        #("system_time", 999),
        #("message_count", 7),
      ]),
      metadata: dict.from_list([
        #("model", "llama"),
        #("error_type", "api_error"),
      ]),
    )
  let assert events.InferenceException(
    model:,
    message_count:,
    error_type:,
    settings: _,
  ) = events.decode(raw)
  assert model == "llama"
  assert message_count == 7
  assert error_type == "api_error"
}

// ── emit_to Tests ──────────────────────────────────────────────────

/// to_dispatcher sends a SessionEvent to the dispatcher.
/// Uses the process.receive pattern — no sleep needed.
pub fn to_dispatcher_sends_event_to_dispatcher_test() {
  let assert Ok(disp) = dispatcher.start()
  let consumer = process.new_subject()
  dispatcher.register_consumer(disp, consumer)

  let event =
    InferenceStarted(
      model: "gpt-4",
      message_count: 3,
      settings: provider.default_settings(),
    )
  emit.to_dispatcher(disp, event)

  let assert Ok(received) = process.receive(consumer, 2000)
  let assert InferenceStarted(model:, message_count:, settings: _) = received
  assert model == "gpt-4"
  assert message_count == 3

  process.send(disp, dispatcher.Stop)
}

/// to_dispatcher triggers telemetry projection.
/// Uses the test listener to verify telemetry was emitted.
pub fn to_dispatcher_triggers_telemetry_test() {
  let handle = listener.attach()
  let assert Ok(disp) = dispatcher.start()
  let consumer = process.new_subject()
  dispatcher.register_consumer(disp, consumer)

  let event =
    InferenceStarted(
      model: "gpt-4",
      message_count: 3,
      settings: provider.default_settings(),
    )
  emit.to_dispatcher(disp, event)

  // Confirm via consumer (guarantees telemetry already fired)
  let assert Ok(_) = process.receive(consumer, 2000)

  let captured = listener.get_events(handle)
  let assert [events.InferenceStart(model:, ..)] = captured
  assert model == "gpt-4"

  listener.detach(handle)
  process.send(disp, dispatcher.Stop)
}

/// to_dispatcher works with all SessionEvent variants.
pub fn to_dispatcher_sends_all_variants_test() {
  let assert Ok(disp) = dispatcher.start()
  let consumer = process.new_subject()
  dispatcher.register_consumer(disp, consumer)

  // Send multiple events and verify they're all received
  emit.to_dispatcher(
    disp,
    SessionStarted(
      agent_id: Some("agent-1"),
      agent_name: None,
      model: "gpt-4",
      provider_name: None,
      system_prompt: None,
    ),
  )
  let assert Ok(_) = process.receive(consumer, 2000)

  emit.to_dispatcher(
    disp,
    InferenceStarted(
      model: "gpt-4",
      message_count: 2,
      settings: provider.default_settings(),
    ),
  )
  let assert Ok(_) = process.receive(consumer, 2000)

  emit.to_dispatcher(disp, SessionEnded(NormalEnd))
  let assert Ok(_) = process.receive(consumer, 2000)

  process.send(disp, dispatcher.Stop)
  Nil
}
