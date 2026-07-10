//// Test listener for capturing telemetry events.
////
//// Attaches to `:telemetry` events and accumulates them into an ETS table.
//// Returns typed `List(Event)` for assertion in tests.
//// Designed for use in tests — no sleeping or polling needed.

import gleam/list
import pig/obs/events.{type Event, type RawCapturedEvent}

/// Handle to an attached listener. Do not construct directly.
pub type ListenerHandle

@external(erlang, "pig_obs_ffi", "attach_listener")
fn ffi_attach(event_names: List(List(String))) -> ListenerHandle

@external(erlang, "pig_obs_ffi", "get_captured_names")
fn ffi_get_captured_names(handle: ListenerHandle) -> List(List(String))

@external(erlang, "pig_obs_ffi", "get_captured_events")
fn ffi_get_captured_events(handle: ListenerHandle) -> List(RawCapturedEvent)

@external(erlang, "pig_obs_ffi", "get_captured_count")
fn ffi_get_captured_count(handle: ListenerHandle) -> Int

@external(erlang, "pig_obs_ffi", "detach_listener")
fn ffi_detach(handle: ListenerHandle) -> Nil

/// Attach a listener that captures all pig telemetry events.
pub fn attach() -> ListenerHandle {
  ffi_attach(events.all_event_names())
}

/// Attach a listener for specific event names only.
pub fn attach_to(names: List(List(String))) -> ListenerHandle {
  ffi_attach(names)
}

/// Get all captured events as typed `Event` values, in emission order.
pub fn get_events(handle: ListenerHandle) -> List(Event) {
  ffi_get_captured_events(handle)
  |> list.map(events.decode)
}

/// Get all captured event names as raw strings, in emission order.
pub fn get_event_names(handle: ListenerHandle) -> List(List(String)) {
  ffi_get_captured_names(handle)
}

/// Get the number of captured events.
pub fn event_count(handle: ListenerHandle) -> Int {
  ffi_get_captured_count(handle)
}

/// Detach the listener and clean up resources.
pub fn detach(handle: ListenerHandle) -> Nil {
  ffi_detach(handle)
}
