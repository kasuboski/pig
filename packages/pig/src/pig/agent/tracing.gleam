//// Runtime-owned trace handles and exception cleanup. Never used by the pure core.

import otel/context
import pig_otel

// The marker must be defined in the consumer OTP application.
fn marker() -> Nil {
  Nil
}

/// Reacquire the consumer tracer at each accepted operation.
@internal
pub fn backend(policy: pig_otel.Policy) -> pig_otel.Backend {
  pig_otel.backend(policy, marker)
}

/// Register a handle before returning it to an in-progress runtime transition.
@internal
pub fn start(
  backend: pig_otel.Backend,
  parent: context.Context,
  operation: pig_otel.Operation,
) -> pig_otel.Span {
  let span = pig_otel.start(backend, parent, operation)
  register(span)
  span
}

/// Finalize an owned operation and remove it from exception cleanup.
@internal
pub fn finish(span: pig_otel.Span, outcome: pig_otel.Outcome) -> Nil {
  unregister(span)
  pig_otel.finish(span, outcome)
}

/// Protect live runtime-owned spans even when a user hook raises mid-transition.
/// The original exception (including its stack) wins over cleanup failures.
@internal
pub fn protect(work: fn() -> a) -> a {
  guard(work, fn(span) {
    pig_otel.finish(span, pig_otel.Failed("callback_error"))
  })
}

@external(erlang, "pig_tracing_ffi", "register")
fn register(span: pig_otel.Span) -> Nil

@external(erlang, "pig_tracing_ffi", "unregister")
fn unregister(span: pig_otel.Span) -> Nil

@external(erlang, "pig_tracing_ffi", "protect")
fn guard(work: fn() -> a, cleanup: fn(pig_otel.Span) -> Nil) -> a
