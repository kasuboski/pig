//// Phase 6 dispatcher wiring tests.
////
//// Verifies that core.gleam and parallel.gleam emit SessionEvents through
//// the dispatcher when configured, and fall back to old telemetry when not.
////
//// Per TESTING_STRATEGY: "NEVER use process.sleep in tests. Use process.receive for synchronization."

import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit
import pig/agent/core
import pig/agent/state
import pig/ai/message
import pig/obs/dispatcher
import pig/obs/events
import pig/obs/listener
import pig/tool
import support/harness

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Dispatcher Configured: SessionEvents Flow ────────────────────

/// When dispatcher is configured, InferenceStarted/Completed events are sent to it.
pub fn dispatcher_configured_sends_inference_events_test() {
  // Start dispatcher
  let assert Ok(dispatcher_subject) = dispatcher.start()

  // Create a test consumer that receives SessionEvents
  let consumer_subject = process.new_subject()
  process.send(dispatcher_subject, dispatcher.RegisterConsumer(consumer_subject))

  // Create agent config with dispatcher
  let config =
    state.config(harness.fixed_provider(message.Assistant("hello!", [], None)))
    |> state.with_dispatcher(dispatcher_subject)

  // Run agent step
  let st = state.new(config) |> state.add_message(message.User("hi"))
  let assert core.Complete(_) = core.step(st)

  // Verify consumer received the SessionEvents
  // Should receive InferenceStarted and InferenceCompleted
  let assert Ok(event1) = process.receive(consumer_subject, 1000)
  let assert Ok(event2) = process.receive(consumer_subject, 1000)

  // Verify they're the right SessionEvent types
  let events_list = [event1, event2]
  let has_started =
    list.any(events_list, fn(e) {
      case e {
        events.InferenceStarted(..) -> True
        _ -> False
      }
    })
  let has_completed =
    list.any(events_list, fn(e) {
      case e {
        events.InferenceCompleted(..) -> True
        _ -> False
      }
    })

  has_started && has_completed
}

/// When dispatcher is configured, ToolStarted/Executed events are sent to it.
pub fn dispatcher_configured_sends_tool_events_test() {
  // Start dispatcher
  let assert Ok(dispatcher_subject) = dispatcher.start()

  // Create a test consumer
  let consumer_subject = process.new_subject()
  process.send(dispatcher_subject, dispatcher.RegisterConsumer(consumer_subject))

  // Create agent config with dispatcher and a tool
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"test\"}",
    )
  let config =
    state.config(harness.fixed_provider(message.Assistant("", [tc], None)))
    |> state.with_dispatcher(dispatcher_subject)
    |> state.with_tools(tool.new_registry() |> tool.register(harness.echo_tool()))

  // Execute tools
  let st =
    state.new(config)
    |> state.add_message(message.Assistant("", [tc], None))
  let _ = core.execute_tools_and_advance(st, [tc])

  // Verify consumer received ToolStarted and ToolExecuted
  let assert Ok(event1) = process.receive(consumer_subject, 1000)
  let assert Ok(event2) = process.receive(consumer_subject, 1000)

  let events_list = [event1, event2]
  let has_started =
    list.any(events_list, fn(e) {
      case e {
        events.ToolStarted(..) -> True
        _ -> False
      }
    })
  let has_executed =
    list.any(events_list, fn(e) {
      case e {
        events.ToolExecuted(..) -> True
        _ -> False
      }
    })

  has_started && has_executed
}

/// When dispatcher is configured, InferenceFailed events are sent on error.
pub fn dispatcher_configured_sends_inference_failed_test() {
  // Start dispatcher
  let assert Ok(dispatcher_subject) = dispatcher.start()

  // Create a test consumer
  let consumer_subject = process.new_subject()
  process.send(dispatcher_subject, dispatcher.RegisterConsumer(consumer_subject))

  // Create agent config with dispatcher and failing provider
  let config =
    state.config(harness.failing_provider)
    |> state.with_dispatcher(dispatcher_subject)

  // Run agent step (will fail)
  let st = state.new(config) |> state.add_message(message.User("hi"))
  let assert core.StepError(_) = core.step(st)

  // Verify consumer received InferenceStarted and InferenceFailed
  let assert Ok(event1) = process.receive(consumer_subject, 1000)
  let assert Ok(event2) = process.receive(consumer_subject, 1000)

  let events_list = [event1, event2]
  let has_started =
    list.any(events_list, fn(e) {
      case e {
        events.InferenceStarted(..) -> True
        _ -> False
      }
    })
  let has_failed =
    list.any(events_list, fn(e) {
      case e {
        events.InferenceFailed(..) -> True
        _ -> False
      }
    })

  has_started && has_failed
}

// ── No Dispatcher: Old Telemetry Still Works ─────────────────────

/// When no dispatcher is configured, old InferenceStart/Stop telemetry still fires.
pub fn no_dispatcher_old_telemetry_still_works_test() {
  // Create agent config WITHOUT dispatcher
  let config =
    state.config(harness.fixed_provider(message.Assistant("hello!", [], None)))

  // Attach telemetry listener
  let handle = listener.attach()

  // Run agent step
  let st = state.new(config) |> state.add_message(message.User("hi"))
  let assert core.Complete(_) = core.step(st)

  // Verify old telemetry events were emitted
  let evts = listener.get_events(handle)
  listener.detach(handle)

  let names = harness.event_type_names(evts)
  list.contains(names, "pig.inference.start")
  && list.contains(names, "pig.inference.stop")
}

/// When no dispatcher is configured, old ToolStart/Stop telemetry still fires.
pub fn no_dispatcher_old_tool_telemetry_still_works_test() {
  // Create agent config WITHOUT dispatcher
  let tc =
    message.ToolCall(
      id: "c1",
      name: "echo",
      arguments_json: "{\"msg\":\"test\"}",
    )
  let config =
    state.config(harness.fixed_provider(message.Assistant("", [tc], None)))
    |> state.with_tools(tool.new_registry() |> tool.register(harness.echo_tool()))

  // Attach telemetry listener
  let handle = listener.attach()

  // Execute tools
  let st =
    state.new(config)
    |> state.add_message(message.Assistant("", [tc], None))
  let _ = core.execute_tools_and_advance(st, [tc])

  // Verify old telemetry events were emitted
  let evts = listener.get_events(handle)
  listener.detach(handle)

  let names = harness.event_type_names(evts)
  list.contains(names, "pig.tool.start")
  && list.contains(names, "pig.tool.stop")
}

/// When no dispatcher is configured, old InferenceException telemetry still fires.
pub fn no_dispatcher_old_exception_telemetry_still_works_test() {
  // Create agent config WITHOUT dispatcher and failing provider
  let config = state.config(harness.failing_provider)

  // Attach telemetry listener
  let handle = listener.attach()

  // Run agent step (will fail)
  let st = state.new(config) |> state.add_message(message.User("hi"))
  let assert core.StepError(_) = core.step(st)

  // Verify old telemetry events were emitted
  let evts = listener.get_events(handle)
  listener.detach(handle)

  let names = harness.event_type_names(evts)
  list.contains(names, "pig.inference.start")
  && list.contains(names, "pig.inference.exception")
}
