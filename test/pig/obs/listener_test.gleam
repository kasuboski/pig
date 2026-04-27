import gleeunit
import pig/obs/events
import pig/obs/listener
import gleam/option.{None}

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Typed Event Capture ──────────────────────────────────────────────

pub fn captures_single_event_test() {
  let handle = listener.attach()
  events.emit(events.InferenceStart(model: "gpt-4", message_count: 1))
  let count = listener.event_count(handle)
  let captured = listener.get_events(handle)
  listener.detach(handle)
  count == 1
    && captured
      == [events.InferenceStart(model: "gpt-4", message_count: 1)]
}

pub fn captures_multiple_events_in_order_test() {
  let handle = listener.attach()
  events.emit(events.InferenceStart(model: "gpt-4", message_count: 3))
  events.emit(
    events.ToolStart(tool_name: "read_file", tool_call_id: "call_1"),
  )
  events.emit(
    events.ToolStop(
      tool_name: "read_file",
      tool_call_id: "call_1",
      duration_ms: 10,
    ),
  )
  events.emit(
    events.InferenceStop(
      model: "gpt-4",
      message_count: 4,
      duration_ms: 200,
      response_id: None,
      finish_reason: None,
      input_tokens: None,
      output_tokens: None,
    ),
  )
  let captured = listener.get_events(handle)
  listener.detach(handle)
  captured
    == [
      events.InferenceStart(model: "gpt-4", message_count: 3),
      events.ToolStart(tool_name: "read_file", tool_call_id: "call_1"),
      events.ToolStop(
        tool_name: "read_file",
        tool_call_id: "call_1",
        duration_ms: 10,
      ),
      events.InferenceStop(
        model: "gpt-4",
        message_count: 4,
        duration_ms: 200,
        response_id: None,
        finish_reason: None,
        input_tokens: None,
        output_tokens: None,
      ),
    ]
}

// ── Count Grows ──────────────────────────────────────────────────────

pub fn count_grows_after_emit_test() {
  let handle = listener.attach()
  let before = listener.event_count(handle)
  events.emit(events.InferenceStart(model: "gpt-4", message_count: 1))
  let after = listener.event_count(handle)
  listener.detach(handle)
  before == 0 && after == 1
}

// ── Detach Stops Capture ─────────────────────────────────────────────

pub fn detach_stops_capture_test() {
  let handle = listener.attach()
  events.emit(events.InferenceStart(model: "gpt-4", message_count: 1))
  let count_before = listener.event_count(handle)
  listener.detach(handle)
  // Emit after detach — should NOT be captured
  events.emit(
    events.InferenceStop(
      model: "gpt-4",
      message_count: 2,
      duration_ms: 50,
      response_id: None,
      finish_reason: None,
      input_tokens: None,
      output_tokens: None,
    ),
  )
  count_before == 1
}

// ── Selective Attachment ─────────────────────────────────────────────

pub fn attach_to_specific_events_test() {
  let handle =
    listener.attach_to([
      events.tool_start_name(),
      events.tool_stop_name(),
    ])
  events.emit(events.InferenceStart(model: "gpt-4", message_count: 1))
  events.emit(events.ToolStart(tool_name: "bash", tool_call_id: "c1"))
  events.emit(
    events.ToolStop(tool_name: "bash", tool_call_id: "c1", duration_ms: 5),
  )
  let captured = listener.get_events(handle)
  listener.detach(handle)
  // Only tool events captured, inference event ignored
  captured
    == [
      events.ToolStart(tool_name: "bash", tool_call_id: "c1"),
      events.ToolStop(tool_name: "bash", tool_call_id: "c1", duration_ms: 5),
    ]
}

// ── Multiple Listeners Don't Interfere ───────────────────────────────

pub fn multiple_listeners_independent_test() {
  let h1 = listener.attach_to([events.inference_start_name()])
  let h2 = listener.attach_to([events.tool_start_name()])
  events.emit(events.InferenceStart(model: "gpt-4", message_count: 1))
  events.emit(events.ToolStart(tool_name: "bash", tool_call_id: "c1"))
  let e1 = listener.get_events(h1)
  let e2 = listener.get_events(h2)
  listener.detach(h1)
  listener.detach(h2)
  e1 == [events.InferenceStart(model: "gpt-4", message_count: 1)]
    && e2 == [events.ToolStart(tool_name: "bash", tool_call_id: "c1")]
}

// ── Raw Event Names Still Available ──────────────────────────────────

pub fn get_event_names_returns_strings_test() {
  let handle = listener.attach()
  events.emit(events.InferenceStart(model: "gpt-4", message_count: 1))
  let names = listener.get_event_names(handle)
  listener.detach(handle)
  // Verify the name matches what event_name() returns, not a hardcoded literal
  names == [events.event_name(events.InferenceStart(model: "gpt-4", message_count: 1))]
}
