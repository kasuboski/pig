//// Deterministic lifecycle tests for standalone consumer ownership.

import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/supervision
import gleeunit
import pig
import pig/obs/consumer_spec
import pig/obs/events.{type SessionEvent}

pub fn main() {
  gleeunit.main()
}

fn unused_supervised_spec() -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    Error(actor.InitFailed("unused in standalone lifecycle test"))
  })
}

fn lifecycle_spec(
  label: String,
  lifecycle: process.Subject(String),
  consumed: process.Subject(Nil),
  fail_to_start: Bool,
) -> consumer_spec.ConsumerSpec {
  let start_fn = fn() {
    process.send(lifecycle, "started:" <> label)
    case fail_to_start {
      True -> Error(actor.InitFailed("consumer " <> label <> " failed"))
      False ->
        Ok(
          consumer_spec.started(
            fn(_event: SessionEvent) { process.send(consumed, Nil) },
            fn() { process.send(lifecycle, "stopped:" <> label) },
          ),
        )
    }
  }
  consumer_spec.ConsumerSpec(
    spec: unused_supervised_spec(),
    name: process.new_name("lifecycle_" <> label),
    start_fn:,
  )
}

pub fn startup_stops_acquired_consumers_and_short_circuits_test() {
  let lifecycle = process.new_subject()
  let consumed = process.new_subject()
  let config =
    pig.test_harness()
    |> pig.with_consumer_specs([
      lifecycle_spec("first", lifecycle, consumed, False),
      lifecycle_spec("second", lifecycle, consumed, False),
      lifecycle_spec("failed", lifecycle, consumed, True),
      lifecycle_spec("never", lifecycle, consumed, False),
    ])

  let assert Error(pig.ActorStart(actor.InitFailed(_))) = pig.start(config)
  let assert Ok("started:first") = process.receive(lifecycle, 0)
  let assert Ok("started:second") = process.receive(lifecycle, 0)
  let assert Ok("started:failed") = process.receive(lifecycle, 0)
  let assert Ok("stopped:second") = process.receive(lifecycle, 0)
  let assert Ok("stopped:first") = process.receive(lifecycle, 0)
  assert process.receive(lifecycle, 0) == Error(Nil)
}

pub fn stop_stops_all_owned_consumers_after_a_successful_start_test() {
  let lifecycle = process.new_subject()
  let consumed = process.new_subject()
  let config =
    pig.test_harness()
    |> pig.with_consumer_specs([
      lifecycle_spec("first", lifecycle, consumed, False),
      lifecycle_spec("second", lifecycle, consumed, False),
    ])
  let assert Ok(agent) = pig.start(config)
  let assert Ok(_response) = pig.run(agent, "lifecycle")
  let assert Ok(Nil) = process.receive(consumed, 2000)

  pig.stop(agent)

  let assert Ok("started:first") = process.receive(lifecycle, 0)
  let assert Ok("started:second") = process.receive(lifecycle, 0)
  let assert Ok("stopped:first") = process.receive(lifecycle, 0)
  let assert Ok("stopped:second") = process.receive(lifecycle, 0)
  assert process.receive(lifecycle, 0) == Error(Nil)
}
