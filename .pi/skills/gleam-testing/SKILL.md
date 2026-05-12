---
name: gleam-testing
description: Best practices for writing Gleam tests with gleeunit. Use when writing or reviewing Gleam test files, fixing silently-passing tests, or choosing assertion patterns.
---

# Gleam Testing Best Practices

## Critical: gleeunit Only Fails on Panics

Gleeunit tests pass if the function completes without panicking. **Returning `False` does NOT fail the test.** This is the #1 source of silently-passing bogus tests.

```gleam
// ❌ WRONG — returns False, test silently passes
pub fn my_test() {
  value == "expected"
}

// ✅ CORRECT — panics on mismatch
pub fn my_test() {
  assert value == "expected"
}
```

The same applies to boolean expressions as the last line of any test. A bare `count == 4` evaluates and discards. Use assertions.

## Two Assertion Constructs — Do Not Confuse Them

Gleam has **two** distinct assertion mechanisms. They look similar but serve different purposes:

### `assert <bool_expr>` — Boolean Assertion

Evaluates the expression. Panics if it's `False`, continues if it's `True`.

```gleam
assert value == "expected"
assert count == 4
assert mode == "wal" || mode == "memory"
assert string.contains(output, "hello")
assert !string.contains(output, "config")
assert keys == ["alpha", "beta"]
```

### `let assert <pattern> = <expr>` — Assertive Pattern Match

Evaluates the expression, then pattern-matches against the pattern. Panics if the pattern doesn't match. Binds variables from the pattern.

```gleam
let assert Ok(value) = result           // unwraps Ok, panics on Error
let assert Error(e) = result            // unwraps Error, panics on Ok
let assert Some(value) = option_value   // unwraps Some, panics on None
let assert None = maybe_thing           // panics if Some
let assert [item] = list_with_one       // panics unless exactly one element
let assert Ok(Nil) = some_operation()   // asserts Ok(Nil) specifically
```

## Assertion Patterns — When to Use What

| Situation | Use |
|---|---|
| Check exact equality | `assert actual == expected` |
| Check inequality | `assert actual != expected` |
| Compound boolean (OR, AND) | `assert a \|\| b` |
| Assert string/list contains | `assert string.contains(s, "x")` |
| Assert Result is Ok AND use the value | `let assert Ok(val) = result` |
| Assert Result is Ok, don't need value | `let assert Ok(Nil) = result` |
| Assert Result is Error | `let assert Error(e) = result` |
| Assert specific error variant | `let assert Error(NotFound(key: k)) = ...` |
| Assert Option is Some | `let assert Some(v) = option` |
| Assert Option is None | `let assert None = option` |
| Assert list has exactly one element | `let assert [item] = list` |

## Common Pitfalls

### Bare boolean as last expression
```gleam
// ❌ Silent pass on False
pub fn test_something() {
  let assert Ok(value) = compute()
  value == "expected"  // <-- returned, not asserted
}

// ✅ Fix
pub fn test_something() {
  let assert Ok(value) = compute()
  assert value == "expected"
}
```

### Weak vs strong assertions on Results
```gleam
// Weak — only checks it's Ok, not the value
let assert Ok(_) = result

// Stronger — checks the exact value
let assert Ok("expected") = result
```

### Chaining assertions
```gleam
let assert Ok(content) = read(conn, "/file.txt")
assert content == "hello"
```

### assert inside case expressions
```gleam
// ❌ WRONG — `assert` is a statement, not a case branch expression
case msg {
  message.Assistant(content:, ..) ->
    assert string.contains(content, "hello")
  _ -> panic as "expected Assistant"
}

// ✅ Fix — use a block
case msg {
  message.Assistant(content:, ..) -> {
    assert string.contains(content, "hello")
    Nil
  }
  _ -> panic as "expected Assistant"
}

// ✅ Or better — destructure first, then assert
let assert message.Assistant(content:, ..) = msg
assert string.contains(content, "hello")
```

## Test File Structure

```gleam
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

fn with_db(f: fn(sqlight.Connection) -> a) -> a {
  let assert Ok(conn) = sqlight.open(":memory:")
  let assert Ok(Nil) = schema.init(conn)
  let result = f(conn)
  let assert Ok(Nil) = sqlight.close(conn)
  result
}

pub fn my_feature_test() {
  with_db(fn(conn) {
    let assert Ok(Nil) = write(conn, "/file.txt", "hello")
    let assert Ok(content) = read(conn, "/file.txt")
    assert content == "hello"
  })
}
```

## Testing OTP Actors and Processes

### The Golden Rule: Never Use `process.sleep`

**Never use `process.sleep` in tests.** It is brittle, slow, and flaky:

- **Race conditions**: Sleep durations are arbitrary guesses. Too short = flakes. Too long = slow suite.
- **Fragile**: System load, scheduler behavior, or actor changes break your timing assumptions.
- **Unnecessary**: Gleam/OTP gives you `process.receive` and `Subject` for deterministic sync.

Instead, use one of the synchronization patterns below.

### Pattern 1: The `send_and_confirm` Synchronization Pattern

The fundamental building block for testing any actor that fans out or forwards messages:

1. **Start the actor** and get its `Subject`
2. **Register a test `Subject`** as a consumer/subscriber via the actor's public API
3. **Send a message** to the actor through its public API
4. **`process.receive` on the test subject** to block until the actor finishes processing
5. **Now assert** on side effects or the received message itself

```gleam
import gleam/erlang/process

// Generic helper — adapt the types to your actor
fn send_and_confirm(
  actor: process.Subject(actor_message),
  msg: actor_message,
  test_consumer: process.Subject(output),
) -> output {
  process.send(actor, msg)
  let assert Ok(received) = process.receive(test_consumer, 2000)
  received
}

pub fn my_actor_test() {
  let assert Ok(actor) = my_actor.start()
  let consumer = process.new_subject()
  process.send(actor, my_actor.Subscribe(consumer))

  let received = send_and_confirm(actor, my_actor.DoSomething("hello"), consumer)
  assert received == expected

  process.send(actor, my_actor.Stop)
}
```

**Why this works:** If the actor processes the message (including any side effects) *before* forwarding to consumers, then receiving on the consumer guarantees all side effects completed. No race, no sleep.

### Pattern 2: The Test Listener (Instrumented Side-Effect Capture)

For actors that produce side effects you cannot observe via consumer subscription (telemetry, logging, metrics), use a **test listener**: a lightweight observer that attaches through the public interface and captures outputs for assertion.

The test listener does NOT mock or replace the actor. The actor runs its real code path. The listener is purely an observation tool.


**Steps:**
1. **Attach** the listener before starting the actor
2. **Start the actor** and register a test consumer
3. **Send a message** and confirm via `send_and_confirm`
4. **Query the listener** for captured side effects
5. **Assert** on the captured data
6. **Detach** the listener in cleanup

```gleam
pub fn test_actor_produces_side_effect() {
  let listener = my_listener.attach()           // 1. attach observer
  let assert Ok(actor) = my_actor.start()       // 2. start actor
  let consumer = process.new_subject()
  process.send(actor, my_actor.Subscribe(consumer))

  send_and_confirm(actor, my_actor.DoX(), consumer)  // 3. exercise

  let captured = my_listener.get_events(listener)     // 4. query
  let assert [XHappened(detail:)] = captured         // 5. assert
  assert detail == "expected"

  my_listener.detach(listener)                       // 6. cleanup
  process.send(actor, my_actor.Stop)
}
```

**Negative assertions** work the same way — confirm the message was processed, then assert the listener captured nothing:

```gleam
  send_and_confirm(actor, my_actor.DoY(), consumer)
  let assert [] = my_listener.get_events(listener)
```

### Pattern 3: Setup/Cleanup Helpers

Combine actor start + consumer registration + listener attachment into reusable helpers. Return a tuple of `(handles, cleanup_fn)`:

```gleam
fn setup() {
  let assert Ok(actor) = my_actor.start()
  let consumer = process.new_subject()
  process.send(actor, my_actor.Subscribe(consumer))
  #(
    #(actor, consumer),
    fn() { process.send(actor, my_actor.Stop) },
  )
}

fn setup_with_listener() {
  let listener = my_listener.attach()
  let assert Ok(actor) = my_actor.start()
  let consumer = process.new_subject()
  process.send(actor, my_actor.Subscribe(consumer))
  #(
    #(actor, consumer, listener),
    fn() {
      my_listener.detach(listener)
      process.send(actor, my_actor.Stop)
    },
  )
}

pub fn test_with_helper() {
  let #(#(actor, consumer, listener), cleanup) = setup_with_listener()
  // ... test code ...
  cleanup()
}
```

### Concrete Example: Dispatcher Actor Tests

Here is how the patterns above look in practice, from `test/pig/obs/dispatcher_test.gleam`. The dispatcher is an actor that receives `SessionEvent`s, emits `:telemetry` as a side effect, then fans out to registered consumers.

```gleam
// The send_and_confirm helper — sends event, blocks until consumer confirms receipt
fn send_and_confirm(
  disp: process.Subject(dispatcher.DispatcherMessage),
  event: events.SessionEvent,
  consumer: process.Subject(events.SessionEvent),
) -> events.SessionEvent {
  process.send(disp, dispatcher.Event(event))
  let assert Ok(received) = process.receive(consumer, 2000)
  received
}

// Setup helper with a :telemetry listener attached (Pattern 3)
fn setup_with_listener() {
  let handle = listener.attach()           // attach telemetry capture
  let assert Ok(disp) = dispatcher.start()
  let consumer = process.new_subject()
  process.send(disp, dispatcher.RegisterConsumer(consumer))
  #(
    #(disp, consumer, handle),
    fn() {
      listener.detach(handle)
      process.send(disp, dispatcher.Stop)
    },
  )
}

// Test: positive assertion — event produces the right telemetry (Pattern 2)
pub fn dispatcher_emits_inference_start_telemetry_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  let event = InferenceStarted(model: "gpt-4", message_count: 3)
  send_and_confirm(disp, event, consumer)

  let captured = listener.get_events(handle)
  let assert [InferenceStart(model:, message_count:)] = captured
  assert model == "gpt-4"
  assert message_count == 3

  cleanup()
}

// Test: negative assertion — event does NOT produce telemetry (Pattern 2)
pub fn dispatcher_does_not_emit_telemetry_for_session_ended_test() {
  let #(#(disp, consumer, handle), cleanup) = setup_with_listener()

  send_and_confirm(disp, SessionEnded(reason: NormalEnd), consumer)
  let assert [] = listener.get_events(handle)

  cleanup()
}
```

### Testing Resilience (Dead Consumers, Dynamic Registration)

These are specializations of Pattern 1, using `send_and_confirm` to prove the actor is still alive after adverse conditions:

**Dead consumer resilience** — register an abandoned subject, send an event (actor must not crash), then prove it's alive by registering a live consumer and sending again:

```gleam
pub fn test_dead_consumer_does_not_crash_actor() {
  let assert Ok(actor) = my_actor.start()
  let dead = process.new_subject()
  process.send(actor, my_actor.Subscribe(dead))
  process.send(actor, my_actor.DoSomething())  // must not crash

  // Prove actor is still alive with a new consumer
  let live = process.new_subject()
  process.send(actor, my_actor.Subscribe(live))
  let received = send_and_confirm(actor, my_actor.DoSomethingElse(), live)
  // assert on received...

  process.send(actor, my_actor.Stop)
}
```

**Dynamic registration** — send before any consumer exists (nobody receives), then register and confirm the next message arrives:

```gleam
pub fn test_dynamic_registration() {
  let assert Ok(actor) = my_actor.start()
  process.send(actor, my_actor.Event(first))  // no consumer yet

  let consumer = process.new_subject()
  process.send(actor, my_actor.Subscribe(consumer))

  let received = send_and_confirm(actor, my_actor.Event(second), consumer)
  assert received == second

  process.send(actor, my_actor.Stop)
}
```
