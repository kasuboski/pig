//// In-memory transport adapter for tests.
////
//// The second adapter that makes the transport seam real (the production
//// hackney adapter is the first). Serves a scripted queue of responses in
//// call order so retry/fallback/circuit scenarios can be driven
//// deterministically with no network and no sleeping.

import gleam/erlang/process
import gleam/otp/actor
import pig_proxy/transport

pub type InMemoryMsg {
  Next(reply_to: process.Subject(transport.TransportResponse))
}

type State {
  State(
    queue: List(transport.TransportResponse),
    /// Returned once the queue is exhausted, so a test that under-scripts
    /// gets a deterministic error rather than crashing.
    exhausted: transport.TransportResponse,
  )
}

fn handle_message(state: State, msg: InMemoryMsg) {
  case msg {
    Next(reply_to) -> {
      case state.queue {
        [next, ..rest] -> {
          process.send(reply_to, next)
          actor.continue(State(..state, queue: rest))
        }
        [] -> {
          process.send(reply_to, state.exhausted)
          actor.continue(state)
        }
      }
    }
  }
}

/// Start an in-memory transport serving `queue` in call order. Once the
/// queue is exhausted it keeps returning `exhausted`.
pub fn start(
  queue: List(transport.TransportResponse),
  exhausted: transport.TransportResponse,
) -> Result(process.Subject(InMemoryMsg), actor.StartError) {
  let result =
    State(queue:, exhausted:)
    |> actor.new
    |> actor.on_message(handle_message)
    |> actor.start
  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Build a `transport.Transport` backed by an in-memory actor.
pub fn transport(
  subject: process.Subject(InMemoryMsg),
) -> transport.Transport {
  transport.Transport(sync: fn(_req) {
    actor.call(subject, waiting: 5000, sending: fn(reply_to) { Next(reply_to) })
  })
}
