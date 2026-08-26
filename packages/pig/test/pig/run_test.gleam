//// Deterministic lifecycle tests for the streaming runtime.
////
//// Provider and tool gates make every race explicit. These tests use mailbox
//// acknowledgements instead of sleeps or process identity assertions.

import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None}
import gleeunit
import jscheam/schema
import pig/agent/runtime
import pig/hooks
import pig/obs/consumer_spec
import pig/obs/dispatcher
import pig/obs/events
import pig/obs/listener
import pig/provider
import pig/run
import pig/run_error
import pig/tool
import pig_protocol/error
import pig_protocol/inference
import pig_protocol/message
import pig_protocol/tool_definition

pub fn main() -> Nil {
  gleeunit.main()
}

type RuntimeSetup {
  RuntimeSetup(
    subject: process.Subject(runtime.RuntimeMsg),
    dispatcher: process.Subject(dispatcher.DispatcherMessage),
  )
}

fn setup(
  provider_instance: provider.Provider,
  tools: List(tool.Tool),
  hooks_list: List(hooks.Hooks),
) -> RuntimeSetup {
  let assert Ok(dispatcher) = dispatcher.start()
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let config =
    runtime.RuntimeConfig(
      provider: provider_instance,
      tools: registry,
      hooks: hooks_list,
      dispatcher:,
      model: "run-test-model",
      max_iterations: 50,
      inference_settings: provider.default_settings(),
    )
  let assert Ok(subject) = runtime.start(config)
  RuntimeSetup(subject:, dispatcher:)
}

fn cleanup(setup: RuntimeSetup) -> Nil {
  runtime.stop(setup.subject)
  process.send(setup.dispatcher, dispatcher.Stop)
}

fn fake_runtime(
  ready: process.Subject(process.Subject(runtime.RuntimeMsg)),
  request_received: process.Subject(Nil),
) -> process.Pid {
  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    process.send(ready, subject)
    case process.receive_forever(subject) {
      runtime.StartPrompt(..) | runtime.StartContinue(..) -> {
        process.send(request_received, Nil)
        process.receive_forever(process.new_subject())
      }
      _ -> Nil
    }
  })
}

pub fn prompt_start_returns_when_runtime_dies_before_reply_test() {
  let ready = process.new_subject()
  let request_received = process.new_subject()
  let result = process.new_subject()
  let fake = fake_runtime(ready, request_received)
  let assert Ok(subject) = process.receive(ready, 1000)
  let _caller =
    process.spawn_unlinked(fn() {
      let sink = process.new_subject()
      process.send(result, runtime.stream(subject, "prompt", sink))
    })
  let assert Ok(Nil) = process.receive(request_received, 1000)
  process.kill(fake)
  let assert Ok(Error(run_error.RuntimeStartUnavailable)) =
    process.receive(result, 1000)
}

pub fn continuation_start_returns_when_runtime_dies_before_reply_test() {
  let ready = process.new_subject()
  let request_received = process.new_subject()
  let result = process.new_subject()
  let fake = fake_runtime(ready, request_received)
  let assert Ok(subject) = process.receive(ready, 1000)
  let _caller =
    process.spawn_unlinked(fn() {
      let sink = process.new_subject()
      process.send(result, runtime.stream_continue(subject, sink))
    })
  let assert Ok(Nil) = process.receive(request_received, 1000)
  process.kill(fake)
  let assert Ok(Error(run_error.RuntimeStartUnavailable)) =
    process.receive(result, 1000)
}

fn tool_call() -> message.ToolCall {
  message.ToolCall(id: "call-1", name: "gate", arguments_json: "{}")
}

fn gate_tool(
  started: process.Subject(Nil),
  gate_ready: process.Subject(process.Subject(Nil)),
) -> tool.Tool {
  tool.Tool(definition: tool_definition("gate"), handler: fn(_, _) {
    process.send(started, Nil)
    let gate = process.new_subject()
    process.send(gate_ready, gate)
    let _ = process.receive(gate, 5000)
    Ok(json.string("tool-result"))
  })
}

fn tool_definition(name: String) -> tool_definition.ToolDefinition {
  tool_definition.ToolDefinition(
    name:,
    description: "test gate",
    parameters: schema.object([]),
  )
}

fn single_round_provider(
  started: process.Subject(Nil),
  gate_ready: process.Subject(process.Subject(Nil)),
) -> provider.Provider {
  provider.from_streaming(fn(_, emit) {
    process.send(started, Nil)
    let gate = process.new_subject()
    process.send(gate_ready, gate)
    let _ = process.receive(gate, 5000)
    emit(provider.Delta(inference.TextDelta("partial")))
    emit(
      provider.Finished(
        Ok(provider.from_message(message.Assistant("complete", [], None, None))),
      ),
    )
  })
}

fn multi_round_provider() -> provider.Provider {
  provider.from_streaming(fn(request, emit) {
    case
      list.any(request.messages, fn(item) {
        case item {
          message.Tool(..) -> True
          _ -> False
        }
      })
    {
      True -> {
        emit(provider.Delta(inference.TextDelta("second")))
        emit(
          provider.Finished(
            Ok(
              provider.from_message(message.Assistant("final", [], None, None)),
            ),
          ),
        )
      }
      False -> {
        emit(provider.Delta(inference.TextDelta("first")))
        emit(
          provider.Finished(
            Ok(
              provider.from_message(message.Assistant(
                "",
                [tool_call()],
                None,
                None,
              )),
            ),
          ),
        )
      }
    }
  })
}

fn next_event(sink: process.Subject(run.RunEvent)) -> run.RunEvent {
  let assert Ok(event) = process.receive(sink, 2000)
  event
}

fn take_events(
  sink: process.Subject(run.RunEvent),
  count: Int,
) -> List(run.RunEvent) {
  case count <= 0 {
    True -> []
    False -> [next_event(sink), ..take_events(sink, count - 1)]
  }
}

fn assert_single_terminal(events_list: List(run.RunEvent)) -> Nil {
  let terminals =
    list.filter(events_list, fn(event) {
      case event {
        run.Completed(..) | run.Failed(..) | run.Cancelled(..) -> True
        _ -> False
      }
    })
  assert list.length(terminals) == 1
}

pub fn ordered_provider_tool_provider_stream_test() {
  let setup =
    setup(
      multi_round_provider(),
      [
        tool.Tool(definition: tool_definition("gate"), handler: fn(_, _) {
          Ok(json.string("tool-result"))
        }),
      ],
      [],
    )
  let sink = process.new_subject()
  let assert Ok(_active_run) = runtime.stream(setup.subject, "prompt", sink)
  let received = take_events(sink, 10)
  let assert [
    run.RunStarted,
    run.InferenceStarted(1),
    run.InferenceDelta(1, inference.TextDelta("first")),
    run.InferenceFinished(1, Ok(_)),
    run.ToolStarted(1, _),
    run.ToolFinished(1, _, Ok(_)),
    run.InferenceStarted(2),
    run.InferenceDelta(2, inference.TextDelta("second")),
    run.InferenceFinished(2, Ok(_)),
    run.Completed(_),
  ] = received
  cleanup(setup)
}

pub fn busy_while_inference_is_gated_test() {
  let started = process.new_subject()
  let gate_ready = process.new_subject()
  let setup = setup(single_round_provider(started, gate_ready), [], [])
  let first_sink = process.new_subject()
  let assert Ok(first_run) = runtime.stream(setup.subject, "first", first_sink)
  let assert Ok(run.RunStarted) = process.receive(first_sink, 1000)
  let assert Ok(run.InferenceStarted(1)) = process.receive(first_sink, 1000)
  let assert Ok(Nil) = process.receive(started, 1000)
  let assert Ok(_gate) = process.receive(gate_ready, 1000)

  let second_sink = process.new_subject()
  assert runtime.stream(setup.subject, "second", second_sink)
    == Error(run_error.Busy)
  run.cancel(first_run, run_error.CallerRequested)
  let assert Ok(run.InferenceFinished(1, Error(error.Cancelled))) =
    process.receive(first_sink, 1000)
  let assert Ok(run.Cancelled(run_error.CallerRequested)) =
    process.receive(first_sink, 1000)
  cleanup(setup)
}

pub fn history_remains_responsive_while_inference_is_gated_test() {
  let started = process.new_subject()
  let gate_ready = process.new_subject()
  let setup = setup(single_round_provider(started, gate_ready), [], [])
  let sink = process.new_subject()
  let assert Ok(active_run) = runtime.stream(setup.subject, "history", sink)
  let assert Ok(run.RunStarted) = process.receive(sink, 1000)
  let assert Ok(run.InferenceStarted(1)) = process.receive(sink, 1000)
  let assert Ok(Nil) = process.receive(started, 1000)
  let assert Ok(_gate) = process.receive(gate_ready, 1000)
  assert runtime.history(setup.subject, 1000) == [message.User("history")]
  run.cancel(active_run, run_error.CallerRequested)
  let _ = take_events(sink, 2)
  cleanup(setup)
}

pub fn cancel_during_inference_has_one_terminal_and_no_partial_assistant_test() {
  let started = process.new_subject()
  let gate_ready = process.new_subject()
  let setup = setup(single_round_provider(started, gate_ready), [], [])
  let sink = process.new_subject()
  let assert Ok(active_run) = runtime.stream(setup.subject, "cancel", sink)
  let _ = next_event(sink)
  let _ = next_event(sink)
  let assert Ok(Nil) = process.receive(started, 1000)
  let assert Ok(gate) = process.receive(gate_ready, 1000)
  run.cancel(active_run, run_error.CallerRequested)
  run.cancel(active_run, run_error.CallerRequested)
  let terminal_events = take_events(sink, 2)
  assert_single_terminal(terminal_events)
  assert runtime.history(setup.subject, 1000) == [message.User("cancel")]

  // A source released after cancellation cannot append a late assistant.
  process.send(gate, Nil)
  assert process.receive(sink, 0) == Error(Nil)
  cleanup(setup)
}

pub fn cancel_during_tools_has_one_terminal_and_no_tool_result_history_test() {
  let provider_started = process.new_subject()
  let provider_gate_ready = process.new_subject()
  let tool_started = process.new_subject()
  let tool_gate_ready = process.new_subject()
  let provider_instance =
    provider.from_streaming(fn(request, emit) {
      case
        list.any(request.messages, fn(item) {
          case item {
            message.Tool(..) -> True
            _ -> False
          }
        })
      {
        True ->
          emit(
            provider.Finished(
              Ok(
                provider.from_message(message.Assistant(
                  "should-not-run",
                  [],
                  None,
                  None,
                )),
              ),
            ),
          )
        False -> {
          process.send(provider_started, Nil)
          let provider_gate = process.new_subject()
          process.send(provider_gate_ready, provider_gate)
          let _ = process.receive(provider_gate, 5000)
          emit(
            provider.Finished(
              Ok(
                provider.from_message(message.Assistant(
                  "",
                  [tool_call()],
                  None,
                  None,
                )),
              ),
            ),
          )
        }
      }
    })
  let setup =
    setup(provider_instance, [gate_tool(tool_started, tool_gate_ready)], [])
  let sink = process.new_subject()
  let assert Ok(active_run) = runtime.stream(setup.subject, "tools", sink)
  let _ = next_event(sink)
  let _ = next_event(sink)
  let assert Ok(Nil) = process.receive(provider_started, 1000)
  let assert Ok(provider_gate) = process.receive(provider_gate_ready, 1000)
  process.send(provider_gate, Nil)
  let assert Ok(run.InferenceFinished(1, Ok(_))) = process.receive(sink, 1000)
  let assert Ok(run.ToolStarted(1, _)) = process.receive(sink, 1000)
  let assert Ok(Nil) = process.receive(tool_started, 1000)
  let assert Ok(tool_gate) = process.receive(tool_gate_ready, 1000)

  run.cancel(active_run, run_error.CallerRequested)
  let assert Ok(run.ToolFinished(1, _, Error(_))) = process.receive(sink, 1000)
  let assert Ok(run.Cancelled(run_error.CallerRequested)) =
    process.receive(sink, 1000)
  assert runtime.history(setup.subject, 1000)
    == [message.User("tools"), message.Assistant("", [tool_call()], None, None)]
  assert process.receive(sink, 0) == Error(Nil)

  process.send(tool_gate, Nil)
  cleanup(setup)
}

pub fn stale_run_and_round_events_are_ignored_test() {
  let started = process.new_subject()
  let gate_ready = process.new_subject()
  let setup = setup(single_round_provider(started, gate_ready), [], [])
  let sink = process.new_subject()
  let assert Ok(active_run) = runtime.stream(setup.subject, "stale", sink)
  let _ = next_event(sink)
  let _ = next_event(sink)
  let assert Ok(Nil) = process.receive(started, 1000)
  let assert Ok(gate) = process.receive(gate_ready, 1000)
  let id = run.id(active_run)
  process.send(
    setup.subject,
    runtime.InferenceWorkerEvent(
      id,
      0,
      provider.Delta(inference.TextDelta("stale-round")),
    ),
  )
  process.send(
    setup.subject,
    runtime.InferenceWorkerEvent(
      "different-run",
      1,
      provider.Delta(inference.TextDelta("stale-run")),
    ),
  )
  assert runtime.history(setup.subject, 1000) == [message.User("stale")]
  assert process.receive(sink, 0) == Error(Nil)
  run.cancel(active_run, run_error.CallerRequested)
  let _ = take_events(sink, 2)
  process.send(gate, Nil)
  assert process.receive(sink, 0) == Error(Nil)
  cleanup(setup)
}

pub fn timeout_cancellation_releases_run_for_next_request_test() {
  let started = process.new_subject()
  let gate_ready = process.new_subject()
  let setup = setup(single_round_provider(started, gate_ready), [], [])
  let sink = process.new_subject()
  let assert Ok(active_run) = runtime.stream(setup.subject, "timeout", sink)
  let _ = next_event(sink)
  let _ = next_event(sink)
  let assert Ok(Nil) = process.receive(started, 1000)
  let assert Ok(_gate) = process.receive(gate_ready, 1000)
  assert runtime.collect(active_run, sink, 0)
    == Error(run_error.Cancelled(run_error.DeadlineExceeded))
  let assert Ok(run.InferenceFinished(1, Error(error.Cancelled))) =
    process.receive(sink, 1000)
  let assert Ok(run.Cancelled(run_error.DeadlineExceeded)) =
    process.receive(sink, 1000)

  // The runtime has cleaned up the active operation before accepting another.
  let next_sink = process.new_subject()
  let assert Ok(next_run) = runtime.stream(setup.subject, "next", next_sink)
  run.cancel(next_run, run_error.CallerRequested)
  let _ = take_events(next_sink, 4)
  cleanup(setup)
}

fn emit_many_run_deltas(
  emit: fn(provider.InferenceEvent) -> Nil,
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      emit(provider.Delta(inference.TextDelta("delta")))
      emit_many_run_deltas(emit, remaining - 1)
    }
  }
}

fn high_volume_delta_provider(
  source_ready: process.Subject(process.Pid),
) -> provider.Provider {
  provider.from_streaming(fn(_, emit) {
    process.send(source_ready, process.self())
    emit_many_run_deltas(emit, 10_000)
    process.receive_forever(process.new_subject())
  })
}

pub fn run_collect_timeout_is_not_starved_by_high_volume_deltas_test() {
  let source_ready = process.new_subject()
  let setup = setup(high_volume_delta_provider(source_ready), [], [])
  let sink = process.new_subject()
  let assert Ok(active_run) = runtime.stream(setup.subject, "delta flood", sink)
  let assert Ok(run.RunStarted) = process.receive(sink, 1000)
  let assert Ok(run.InferenceStarted(1)) = process.receive(sink, 1000)
  let assert Ok(source_pid) = process.receive(source_ready, 1000)
  let source_monitor = process.monitor(source_pid)

  assert runtime.collect(active_run, sink, 0)
    == Error(run_error.Cancelled(run_error.DeadlineExceeded))
  await_process_down(source_monitor)
  cleanup(setup)
}

pub fn sink_owner_disconnect_cancels_active_run_test() {
  let started = process.new_subject()
  let gate_ready = process.new_subject()
  let owner_ready = process.new_subject()
  let owner_gate = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      process.send(owner_ready, Nil)
      process.receive_forever(owner_gate)
    })
  let setup = setup(single_round_provider(started, gate_ready), [], [])
  let sink = process.new_subject()
  let assert Ok(_active_run) =
    runtime.stream_owned(setup.subject, "disconnect", sink, owner)
  let _ = next_event(sink)
  let _ = next_event(sink)
  let assert Ok(Nil) = process.receive(owner_ready, 1000)
  let assert Ok(Nil) = process.receive(started, 1000)
  let assert Ok(_gate) = process.receive(gate_ready, 1000)
  process.kill(owner)
  let assert Ok(run.InferenceFinished(1, Error(error.Cancelled))) =
    process.receive(sink, 1000)
  let assert Ok(run.Cancelled(run_error.ClientDisconnected)) =
    process.receive(sink, 1000)
  process.send(owner_gate, Nil)
  cleanup(setup)
}

pub fn stop_cancels_active_work_before_actor_exit_test() {
  let started = process.new_subject()
  let gate_ready = process.new_subject()
  let setup = setup(single_round_provider(started, gate_ready), [], [])
  let sink = process.new_subject()
  let assert Ok(_active_run) = runtime.stream(setup.subject, "stop", sink)
  let _ = next_event(sink)
  let _ = next_event(sink)
  let assert Ok(Nil) = process.receive(started, 1000)
  let assert Ok(gate) = process.receive(gate_ready, 1000)
  runtime.stop(setup.subject)
  let assert Ok(run.InferenceFinished(1, Error(error.Cancelled))) =
    process.receive(sink, 1000)
  let assert Ok(run.Cancelled(run_error.AgentStopped)) =
    process.receive(sink, 1000)
  process.send(gate, Nil)
  assert process.receive(sink, 0) == Error(Nil)
  process.send(setup.dispatcher, dispatcher.Stop)
}

pub fn hooks_session_events_and_telemetry_are_once_without_deltas_test() {
  let hook_events = process.new_subject()
  let hooks_list = [
    hooks.new("run-test")
    |> hooks.on_before_inference(fn(_) {
      process.send(hook_events, "before")
      hooks.KeepMessages
    })
    |> hooks.on_tool_call(fn(_) {
      process.send(hook_events, "tool-call")
      hooks.AllowTool
    })
    |> hooks.on_after_inference(fn(_) { process.send(hook_events, "after") })
    |> hooks.on_tool_result(fn(_) {
      process.send(hook_events, "tool-result")
      hooks.KeepResult
    })
    |> hooks.on_complete(fn(_) { process.send(hook_events, "complete") }),
  ]
  let session_events = process.new_subject()
  let assert Ok(dispatcher) = dispatcher.start()
  let assert Ok(Nil) =
    dispatcher.register_consumer(
      dispatcher,
      consumer_spec.subject_endpoint(session_events),
    )
  let registry =
    tool.register(
      tool.new_registry(),
      tool.Tool(definition: tool_definition("gate"), handler: fn(_, _) {
        Ok(json.string("tool-result"))
      }),
    )
  let config =
    runtime.RuntimeConfig(
      provider: multi_round_provider(),
      tools: registry,
      hooks: hooks_list,
      dispatcher:,
      model: "run-test-model",
      max_iterations: 50,
      inference_settings: provider.default_settings(),
    )
  let assert Ok(subject) = runtime.start(config)
  let telemetry = listener.attach_to(events.all_event_names())
  let sink = process.new_subject()
  let assert Ok(_active_run) = runtime.stream(subject, "observe", sink)
  let _ = take_events(sink, 10)
  dispatcher.flush(dispatcher)

  assert telemetry_names(listener.get_events(telemetry))
    == [
      "inference-start",
      "inference-stop",
      "tool-start",
      "tool-stop",
      "inference-start",
      "inference-stop",
    ]
  let observed = take_session_events(session_events, 6, [])
  assert session_event_names(observed)
    == [
      "inference-started",
      "inference-completed",
      "tool-started",
      "tool-executed",
      "inference-started",
      "inference-completed",
    ]
  let assert Ok("before") = process.receive(hook_events, 1000)
  let assert Ok("after") = process.receive(hook_events, 1000)
  let assert Ok("tool-call") = process.receive(hook_events, 1000)
  let assert Ok("tool-result") = process.receive(hook_events, 1000)
  let assert Ok("before") = process.receive(hook_events, 1000)
  let assert Ok("after") = process.receive(hook_events, 1000)
  let assert Ok("complete") = process.receive(hook_events, 1000)
  assert process.receive(hook_events, 0) == Error(Nil)
  listener.detach(telemetry)
  runtime.stop(subject)
  process.send(dispatcher, dispatcher.Stop)
}

fn take_session_events(
  subject: process.Subject(events.SessionEvent),
  count: Int,
  acc: List(events.SessionEvent),
) -> List(events.SessionEvent) {
  case count <= 0 {
    True -> list.reverse(acc)
    False -> {
      let assert Ok(event) = process.receive(subject, 1000)
      take_session_events(subject, count - 1, [event, ..acc])
    }
  }
}

fn telemetry_names(captured: List(events.Event)) -> List(String) {
  list.map(captured, fn(event) {
    case event {
      events.InferenceStart(..) -> "inference-start"
      events.InferenceStop(..) -> "inference-stop"
      events.ToolStart(..) -> "tool-start"
      events.ToolStop(..) -> "tool-stop"
      events.InferenceException(..) -> "inference-exception"
      events.ToolException(..) -> "tool-exception"
    }
  })
}

fn session_event_names(captured: List(events.SessionEvent)) -> List(String) {
  list.map(captured, fn(event) {
    case event {
      events.InferenceStarted(..) -> "inference-started"
      events.InferenceCompleted(..) -> "inference-completed"
      events.ToolStarted(..) -> "tool-started"
      events.ToolExecuted(..) -> "tool-executed"
      _ -> "unexpected"
    }
  })
}

fn delayed_gate_tool(
  gate_ready: process.Subject(process.Subject(Nil)),
) -> tool.Tool {
  tool.Tool(definition: tool_definition("gate"), handler: fn(_, _) {
    let gate = process.new_subject()
    process.send(gate_ready, gate)
    let _ = process.receive(gate, 6000)
    Ok(json.string("tool-result"))
  })
}

pub fn slow_gated_tool_runs_until_completion_test() {
  let gate_ready = process.new_subject()
  let setup = setup(multi_round_provider(), [delayed_gate_tool(gate_ready)], [])
  let sink = process.new_subject()
  let assert Ok(_active_run) = runtime.stream(setup.subject, "slow", sink)
  let _ = take_events(sink, 5)
  let assert Ok(gate) = process.receive(gate_ready, 1000)
  let _ = process.send_after(gate, 5200, Nil)
  let assert Ok(run.ToolFinished(1, _, Ok(_))) = process.receive(sink, 7000)
  let remaining = take_events(sink, 4)
  let assert [
    run.InferenceStarted(2),
    run.InferenceDelta(2, _),
    run.InferenceFinished(2, Ok(_)),
    run.Completed(_),
  ] = remaining
  cleanup(setup)
}

pub fn duplicate_inactive_tool_event_is_not_observed_test() {
  let hook_events = process.new_subject()
  let hooks_list = [
    hooks.new("duplicate-test")
    |> hooks.on_tool_result(fn(_) {
      process.send(hook_events, "tool-result")
      hooks.KeepResult
    }),
  ]
  let setup =
    setup(
      multi_round_provider(),
      [
        tool.Tool(definition: tool_definition("gate"), handler: fn(_, _) {
          Ok(json.string("tool-result"))
        }),
      ],
      hooks_list,
    )
  let session_events = process.new_subject()
  let assert Ok(Nil) =
    dispatcher.register_consumer(
      setup.dispatcher,
      consumer_spec.subject_endpoint(session_events),
    )
  let telemetry = listener.attach_to(events.all_event_names())
  let sink = process.new_subject()
  let assert Ok(active_run) = runtime.stream(setup.subject, "duplicate", sink)
  let all_events = take_events(sink, 10)
  let assert [
    run.RunStarted,
    run.InferenceStarted(1),
    run.InferenceDelta(1, _),
    run.InferenceFinished(1, Ok(_)),
    run.ToolStarted(1, call),
    run.ToolFinished(1, _, Ok(_)),
    run.InferenceStarted(2),
    run.InferenceDelta(2, _),
    run.InferenceFinished(2, Ok(_)),
    run.Completed(_),
  ] = all_events
  process.send(
    setup.subject,
    runtime.ToolWorkerFinished(
      run.id(active_run),
      1,
      call,
      Error(tool.ToolError(message: "late duplicate")),
      999,
    ),
  )
  let _ = runtime.history(setup.subject, 1000)
  dispatcher.flush(setup.dispatcher)
  assert telemetry_names(listener.get_events(telemetry))
    == [
      "inference-start",
      "inference-stop",
      "tool-start",
      "tool-stop",
      "inference-start",
      "inference-stop",
    ]
  let observed = take_session_events(session_events, 6, [])
  assert session_event_names(observed)
    == [
      "inference-started",
      "inference-completed",
      "tool-started",
      "tool-executed",
      "inference-started",
      "inference-completed",
    ]
  let assert Ok("tool-result") = process.receive(hook_events, 1000)
  assert process.receive(hook_events, 0) == Error(Nil)
  assert process.receive(sink, 0) == Error(Nil)
  listener.detach(telemetry)
  cleanup(setup)
}

pub fn disconnect_during_tools_preserves_cancellation_observability_test() {
  let tool_started = process.new_subject()
  let tool_gate_ready = process.new_subject()
  let owner_ready = process.new_subject()
  let owner_gate = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      process.send(owner_ready, Nil)
      process.receive_forever(owner_gate)
    })
  let hook_events = process.new_subject()
  let hooks_list = [
    hooks.new("disconnect-test")
    |> hooks.on_tool_result(fn(_) {
      process.send(hook_events, "tool-result")
      hooks.KeepResult
    }),
  ]
  let setup =
    setup(
      multi_round_provider(),
      [gate_tool(tool_started, tool_gate_ready)],
      hooks_list,
    )
  let session_events = process.new_subject()
  let assert Ok(Nil) =
    dispatcher.register_consumer(
      setup.dispatcher,
      consumer_spec.subject_endpoint(session_events),
    )
  let telemetry = listener.attach_to(events.all_event_names())
  let sink = process.new_subject()
  let assert Ok(_active_run) =
    runtime.stream_owned(setup.subject, "disconnect-tools", sink, owner)
  let _ = take_events(sink, 5)
  let assert Ok(Nil) = process.receive(owner_ready, 1000)
  let assert Ok(Nil) = process.receive(tool_started, 1000)
  let assert Ok(tool_gate) = process.receive(tool_gate_ready, 1000)
  process.kill(owner)
  let assert Ok(run.ToolFinished(1, _, Error(tool.Cancelled))) =
    process.receive(sink, 1000)
  let assert Ok(run.Cancelled(run_error.ClientDisconnected)) =
    process.receive(sink, 1000)
  dispatcher.flush(setup.dispatcher)
  assert telemetry_names(listener.get_events(telemetry))
    == ["inference-start", "inference-stop", "tool-start", "tool-stop"]
  let observed = take_session_events(session_events, 4, [])
  assert session_event_names(observed)
    == [
      "inference-started",
      "inference-completed",
      "tool-started",
      "tool-executed",
    ]
  let assert Ok("tool-result") = process.receive(hook_events, 1000)
  assert process.receive(hook_events, 0) == Error(Nil)
  process.send(tool_gate, Nil)
  process.send(owner_gate, Nil)
  listener.detach(telemetry)
  cleanup(setup)
}

pub fn collect_prefers_terminal_already_in_mailbox_test() {
  let started = process.new_subject()
  let gate_ready = process.new_subject()
  let setup = setup(single_round_provider(started, gate_ready), [], [])
  let sink = process.new_subject()
  let assert Ok(active_run) =
    runtime.stream(setup.subject, "terminal-race", sink)
  let assert Ok(run.RunStarted) = process.receive(sink, 1000)
  let assert Ok(run.InferenceStarted(1)) = process.receive(sink, 1000)
  let assert Ok(Nil) = process.receive(started, 1000)
  let assert Ok(gate) = process.receive(gate_ready, 1000)
  let message = message.Assistant("terminal", [], None, None)
  process.send(
    setup.subject,
    runtime.InferenceWorkerEvent(
      run.id(active_run),
      1,
      provider.Finished(Ok(provider.from_message(message))),
    ),
  )
  run.cancel(active_run, run_error.CallerRequested)
  let _ = runtime.history(setup.subject, 1000)
  assert runtime.collect(active_run, sink, 0) == Ok(message)
  process.send(gate, Nil)
  cleanup(setup)
}

fn await_process_down(monitor: process.Monitor) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 2000)
  Nil
}

fn gated_inference_provider(
  source_ready: process.Subject(process.Pid),
  gate_ready: process.Subject(process.Subject(Nil)),
) -> provider.Provider {
  provider.from_streaming(fn(_, emit) {
    process.send(source_ready, process.self())
    let gate = process.new_subject()
    process.send(gate_ready, gate)
    let _ = process.receive(gate, 5000)
    emit(
      provider.Finished(
        Ok(provider.from_message(message.Assistant("late", [], None, None))),
      ),
    )
  })
}

fn gated_tool(
  source_ready: process.Subject(process.Pid),
  gate_ready: process.Subject(process.Subject(Nil)),
) -> tool.Tool {
  tool.Tool(definition: tool_definition("gate"), handler: fn(_, _) {
    process.send(source_ready, process.self())
    let gate = process.new_subject()
    process.send(gate_ready, gate)
    let _ = process.receive(gate, 5000)
    Ok(json.string("late"))
  })
}

fn crashing_tool() -> tool.Tool {
  tool.Tool(definition: tool_definition("gate"), handler: fn(_, _) {
    panic as "tool handler crashed"
  })
}

/// A dead runtime makes an active inference unavailable and its provider
/// source is terminated through the worker ownership chain.
pub fn runtime_death_while_awaiting_inference_is_typed_and_cascades_test() {
  let source_ready = process.new_subject()
  let gate_ready = process.new_subject()
  let setup = setup(gated_inference_provider(source_ready, gate_ready), [], [])
  let sink = process.new_subject()
  let assert Ok(active_run) = runtime.stream(setup.subject, "inference", sink)
  let _ = next_event(sink)
  let assert Ok(run.InferenceStarted(1)) = process.receive(sink, 1000)
  let assert Ok(source_pid) = process.receive(source_ready, 1000)
  let assert Ok(_gate) = process.receive(gate_ready, 1000)
  let source_monitor = process.monitor(source_pid)
  let assert Ok(runtime_pid) = process.subject_owner(setup.subject)
  process.unlink(runtime_pid)
  process.kill(runtime_pid)

  assert runtime.collect(active_run, sink, 5000)
    == Error(run_error.RuntimeUnavailable)
  await_process_down(source_monitor)
  cleanup(setup)
}

/// A dead runtime makes an active tool batch unavailable and terminates the
/// handler process owned by the tool worker.
pub fn runtime_death_while_awaiting_tools_is_typed_and_cascades_test() {
  let source_ready = process.new_subject()
  let gate_ready = process.new_subject()
  let provider_instance =
    provider.from_streaming(fn(_, emit) {
      emit(
        provider.Finished(
          Ok(
            provider.from_message(message.Assistant(
              "",
              [tool_call()],
              None,
              None,
            )),
          ),
        ),
      )
    })
  let setup =
    setup(provider_instance, [gated_tool(source_ready, gate_ready)], [])
  let sink = process.new_subject()
  let assert Ok(active_run) = runtime.stream(setup.subject, "tools", sink)
  let _ = take_events(sink, 4)
  let assert Ok(source_pid) = process.receive(source_ready, 1000)
  let assert Ok(_gate) = process.receive(gate_ready, 1000)
  let source_monitor = process.monitor(source_pid)
  let assert Ok(runtime_pid) = process.subject_owner(setup.subject)
  process.unlink(runtime_pid)
  process.kill(runtime_pid)

  assert runtime.collect(active_run, sink, 5000)
    == Error(run_error.RuntimeUnavailable)
  await_process_down(source_monitor)
  cleanup(setup)
}

/// A crashing tool worker reports one fallback result, one terminal observation,
/// and one history message without duplicating the tool result.
pub fn crashing_tool_has_one_terminal_observation_and_clean_history_test() {
  let setup = setup(multi_round_provider(), [crashing_tool()], [])
  let session_events = process.new_subject()
  let assert Ok(Nil) =
    dispatcher.register_consumer(
      setup.dispatcher,
      consumer_spec.subject_endpoint(session_events),
    )
  let sink = process.new_subject()
  let assert Ok(_active_run) = runtime.stream(setup.subject, "crash", sink)
  let stream_events = take_events(sink, 10)
  let tool_finished =
    list.filter(stream_events, fn(event) {
      case event {
        run.ToolFinished(1, _, _) -> True
        _ -> False
      }
    })
  assert list.length(tool_finished) == 1
  let assert [run.ToolFinished(1, _, Error(_))] = tool_finished

  dispatcher.flush(setup.dispatcher)
  let observed = take_session_events(session_events, 6, [])
  let tool_executed =
    list.filter(observed, fn(event) {
      case event {
        events.ToolExecuted(..) -> True
        _ -> False
      }
    })
  assert list.length(tool_executed) == 1
  assert runtime.history(setup.subject, 1000)
    == [
      message.User("crash"),
      message.Assistant("", [tool_call()], None, None),
      message.Tool(
        tool_call_id: "call-1",
        content: "Tool error: tool worker exited before reporting a result",
      ),
      message.Assistant("final", [], None, None),
    ]
  cleanup(setup)
}
