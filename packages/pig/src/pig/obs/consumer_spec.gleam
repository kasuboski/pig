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

/// A control message understood by consumers that are supervised by pig.
///
/// The consumer acknowledges the stop without exiting. The surrounding
/// supervisor exits immediately after the acknowledgement, which avoids a
/// permanent child being restarted during an orderly shutdown.
pub type SupervisedMessage {
  Event(SessionEvent)
  Stop(Subject(Nil))
}

/// Errors returned when a consumer cannot acknowledge a graceful stop.
pub type StopError {
  StopTimeout
}

/// An owned endpoint for a started consumer.
///
/// The consumer owns the details of delivery and shutdown. In particular, a
/// consumer does not need to expose its actor message type to the dispatcher.
pub opaque type StartedConsumer {
  StartedConsumer(
    consume_fn: fn(SessionEvent) -> Nil,
    stop_fn: fn() -> Result(Nil, StopError),
  )
}

/// Build a started consumer endpoint from delivery and shutdown operations.
///
/// This compatibility constructor is for consumers whose stop operation has no
/// typed failure result. Use `started_with_result` when the caller can observe
/// a stop acknowledgement.
pub fn started(
  consume_fn: fn(SessionEvent) -> Nil,
  stop_fn: fn() -> Nil,
) -> StartedConsumer {
  started_with_result(consume_fn, fn() {
    stop_fn()
    Ok(Nil)
  })
}

/// Build a started consumer endpoint with an observable stop result.
pub fn started_with_result(
  consume_fn: fn(SessionEvent) -> Nil,
  stop_fn: fn() -> Result(Nil, StopError),
) -> StartedConsumer {
  StartedConsumer(consume_fn:, stop_fn:)
}

/// Deliver an event to a started consumer.
pub fn consume(consumer: StartedConsumer, event: SessionEvent) -> Nil {
  let StartedConsumer(consume_fn:, ..) = consumer
  consume_fn(event)
}

/// Stop a started consumer, preserving the historical fire-and-forget API.
pub fn stop(consumer: StartedConsumer) -> Nil {
  let _ = stop_with_result(consumer)
  Nil
}

/// Stop a started consumer and return its acknowledgement result.
pub fn stop_with_result(consumer: StartedConsumer) -> Result(Nil, StopError) {
  let StartedConsumer(stop_fn:, ..) = consumer
  stop_fn()
}

/// Adapt a named supervised consumer subject with a graceful stop operation.
pub fn supervised_endpoint(name: Name(SupervisedMessage)) -> StartedConsumer {
  let subject = process.named_subject(name)
  started_with_result(fn(event) { process.send(subject, Event(event)) }, fn() {
    let reply_to = process.new_subject()
    process.send(subject, Stop(reply_to))
    case process.receive(reply_to, 5000) {
      Ok(Nil) -> Ok(Nil)
      Error(Nil) -> Error(StopTimeout)
    }
  })
}

/// Adapt an unowned SessionEvent subject for dynamic dispatcher use.
///
/// The endpoint can deliver events, but has no ownership of the subject's
/// process and therefore has a no-op stop operation.
pub fn subject_endpoint(subject: Subject(SessionEvent)) -> StartedConsumer {
  started(fn(event) { process.send(subject, event) }, fn() { Nil })
}

/// A deferred consumer specification.
pub type ConsumerSpec {
  ConsumerSpec(
    spec: supervision.ChildSpecification(Nil),
    name: Name(SupervisedMessage),
    start_fn: fn() -> Result(StartedConsumer, actor.StartError),
  )
}

/// Build a consumer specification with a gracefully controllable supervised
/// endpoint.
pub fn supervised_spec(
  spec: supervision.ChildSpecification(Nil),
  name: Name(SupervisedMessage),
  start_fn: fn() -> Result(StartedConsumer, actor.StartError),
) -> ConsumerSpec {
  ConsumerSpec(spec:, name:, start_fn:)
}

/// Return the child specification carried by a consumer entry.
pub fn child_spec(entry: ConsumerSpec) -> supervision.ChildSpecification(Nil) {
  let ConsumerSpec(spec:, ..) = entry
  spec
}

/// Build the dispatcher endpoint carried by a consumer entry.
pub fn supervised_endpoint_for(entry: ConsumerSpec) -> StartedConsumer {
  let ConsumerSpec(name:, ..) = entry
  supervised_endpoint(name)
}
