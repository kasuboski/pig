//// Agent event emission tests.
////
//// Verifies that core.gleam emits the correct SessionEvents through the
//// dispatcher for inference, tool execution, and error scenarios.

import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleeunit
import pig/agent/core
import pig/agent/state
import pig/ai/message
import pig/obs/dispatcher
import pig/obs/events
import pig/tool
import support/harness

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Inference Events ──────────────────────────────────────────────

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

  let assert True = has_started && has_completed

  // Cleanup
  process.send(dispatcher_subject, dispatcher.Stop)
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

  let assert True = has_started && has_executed

  // Cleanup
  process.send(dispatcher_subject, dispatcher.Stop)
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

  let assert True = has_started && has_failed

  // Cleanup
  process.send(dispatcher_subject, dispatcher.Stop)
}


