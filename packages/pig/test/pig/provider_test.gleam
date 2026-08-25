//// Contract tests for the opaque streaming provider boundary.

import gleam/erlang/process
import gleam/option.{None}
import gleeunit
import pig/provider
import pig_protocol/error
import pig_protocol/inference as protocol_inference
import pig_protocol/message

pub fn main() -> Nil {
  gleeunit.main()
}

fn request() -> provider.InferenceRequest {
  provider.InferenceRequest(
    messages: [message.User("hello")],
    tools: [],
    settings: provider.default_settings(),
  )
}

pub fn buffered_adapter_emits_only_one_terminal_test() {
  let result = provider.from_message(message.Assistant("done", [], None, None))
  let inference =
    provider.start(provider.from_buffered(fn(_) { Ok(result) }), request())
  let assert Ok(provider.Finished(Ok(actual))) =
    provider.receive(inference, 1000)
  assert actual == result
  assert Error(Nil) == provider.receive(inference, 0)
}

pub fn coordinator_forwards_deltas_before_terminal_test() {
  let inference =
    provider.start(
      provider.from_streaming(fn(_, emit) {
        emit(provider.Delta(protocol_inference.TextDelta("one")))
        emit(provider.Delta(protocol_inference.TextDelta("two")))
        emit(
          provider.Finished(
            Ok(
              provider.from_message(message.Assistant("onetwo", [], None, None)),
            ),
          ),
        )
      }),
      request(),
    )
  let assert Ok(provider.Delta(protocol_inference.TextDelta("one"))) =
    provider.receive(inference, 1000)
  let assert Ok(provider.Delta(protocol_inference.TextDelta("two"))) =
    provider.receive(inference, 1000)
  let assert Ok(provider.Finished(Ok(_))) = provider.receive(inference, 1000)
  assert Error(Nil) == provider.receive(inference, 0)
}

pub fn cancellation_is_idempotent_and_blocks_late_events_test() {
  let started = process.new_subject()
  let gate = process.new_subject()
  let inference =
    provider.start(
      provider.from_streaming(fn(_, emit) {
        process.send(started, Nil)
        process.receive_forever(gate)
        emit(provider.Delta(protocol_inference.TextDelta("late")))
        emit(
          provider.Finished(
            Ok(provider.from_message(message.Assistant("late", [], None, None))),
          ),
        )
      }),
      request(),
    )
  let assert Ok(Nil) = process.receive(started, 1000)
  provider.cancel(inference)
  provider.cancel(inference)
  let assert Ok(provider.Finished(Error(error.Cancelled))) =
    provider.receive(inference, 1000)
  assert Error(Nil) == provider.receive(inference, 0)
  process.send(gate, Nil)
  assert Error(Nil) == provider.receive(inference, 0)
}

pub fn source_without_terminal_is_normalized_to_error_test() {
  let inference =
    provider.start(
      provider.from_streaming(fn(_, emit) {
        emit(provider.Delta(protocol_inference.TextDelta("partial")))
      }),
      request(),
    )
  let assert Ok(provider.Delta(protocol_inference.TextDelta("partial"))) =
    provider.receive(inference, 1000)
  let assert Ok(provider.Finished(Error(error.InvalidResponse(_)))) =
    provider.receive(inference, 1000)
}

pub fn collect_timeout_cancels_source_test() {
  let started = process.new_subject()
  let gate = process.new_subject()
  let inference =
    provider.start(
      provider.from_streaming(fn(_, _) {
        process.send(started, Nil)
        process.receive_forever(gate)
      }),
      request(),
    )
  let assert Ok(Nil) = process.receive(started, 1000)
  let assert Error(error.Timeout) = provider.collect(inference, 0)
  let assert Ok(provider.Finished(Error(error.Cancelled))) =
    provider.receive(inference, 1000)
  process.send(gate, Nil)
}

fn emit_many_deltas(
  emit: fn(provider.InferenceEvent) -> Nil,
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      emit(provider.Delta(protocol_inference.TextDelta("delta")))
      emit_many_deltas(emit, remaining - 1)
    }
  }
}

fn await_process_down(monitor: process.Monitor) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(process.ProcessDown(..)) =
    process.selector_receive(selector, 2000)
  Nil
}

pub fn collect_timeout_is_not_starved_by_high_volume_deltas_test() {
  let source_ready = process.new_subject()
  let inference =
    provider.start(
      provider.from_streaming(fn(_, emit) {
        process.send(source_ready, process.self())
        emit_many_deltas(emit, 10_000)
        process.receive_forever(process.new_subject())
      }),
      request(),
    )
  let assert Ok(source_pid) = process.receive(source_ready, 1000)
  let source_monitor = process.monitor(source_pid)

  assert provider.collect(inference, 0) == Error(error.Timeout)
  await_process_down(source_monitor)
}
