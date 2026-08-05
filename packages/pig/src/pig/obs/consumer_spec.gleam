//// Consumer specifications and owned consumer endpoints.
////
//// A `StartedConsumer` is the narrow endpoint the dispatcher needs: it can
//// deliver a `SessionEvent` and it can be stopped by its owner. Keeping both
//// operations together prevents startup code from losing the process handle
//// that it must clean up on a later failure.

import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision
import pig/obs/events.{type SessionEvent}

/// An owned endpoint for a started consumer.
///
/// The consumer owns the details of delivery and shutdown. In particular, a
/// consumer does not need to expose its actor message type to the dispatcher.
pub opaque type StartedConsumer {
  StartedConsumer(consume_fn: fn(SessionEvent) -> Nil, stop_fn: fn() -> Nil)
}

/// Build a started consumer endpoint from delivery and shutdown operations.
pub fn started(
  consume_fn: fn(SessionEvent) -> Nil,
  stop_fn: fn() -> Nil,
) -> StartedConsumer {
  StartedConsumer(consume_fn:, stop_fn:)
}

/// Deliver an event to a started consumer.
pub fn consume(consumer: StartedConsumer, event: SessionEvent) -> Nil {
  let StartedConsumer(consume_fn:, ..) = consumer
  consume_fn(event)
}

/// Stop a started consumer.
pub fn stop(consumer: StartedConsumer) -> Nil {
  let StartedConsumer(stop_fn:, ..) = consumer
  stop_fn()
}

/// Adapt a named SessionEvent subject for a supervised consumer.
///
/// The supervisor owns the process, so stopping this endpoint is deliberately
/// a no-op. The named subject remains valid when the supervised consumer is
/// reconstructed.
pub fn supervised_endpoint(name: Name(SessionEvent)) -> StartedConsumer {
  let subject = process.named_subject(name)
  started(fn(event) { process.send(subject, event) }, fn() { Nil })
}

/// Adapt an unowned SessionEvent subject for dynamic dispatcher use.
///
/// The endpoint can deliver events, but has no ownership of the subject's
/// process and therefore has a no-op stop operation.
pub fn subject_endpoint(subject: Subject(SessionEvent)) -> StartedConsumer {
  started(fn(event) { process.send(subject, event) }, fn() { Nil })
}

/// A deferred consumer specification.
///
/// `spec` and `name` are used by the supervised startup path. `start_fn` is
/// used by `pig.start` and returns an owned endpoint for the unsupervised
/// path.
pub type ConsumerSpec {
  ConsumerSpec(
    spec: supervision.ChildSpecification(Nil),
    name: Name(SessionEvent),
    start_fn: fn() -> Result(StartedConsumer, actor.StartError),
  )
}
