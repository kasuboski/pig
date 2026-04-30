//// Consumer specification for observability.
////
//// A deferred consumer: a ChildSpec + the name to recover its Subject after start
//// + a start function for the unsupervised path.

import gleam/erlang/process.{type Name, type Subject}
import gleam/otp/actor
import gleam/otp/supervision
import pig/obs/events.{type SessionEvent}

/// A deferred consumer specification.
///
/// Stores:
/// - `spec`: A ChildSpecification for starting this consumer in a supervision tree
/// - `name`: The name to recover the Subject after start (for registration)
/// - `start_fn`: A start function for the unsupervised path (used by `pig.start()`)
pub type ConsumerSpec {
  ConsumerSpec(
    spec: supervision.ChildSpecification(Nil),
    name: Name(SessionEvent),
    start_fn: fn() -> Result(Subject(SessionEvent), actor.StartError),
  )
}
