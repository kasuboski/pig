//// In-memory transport adapter for tests.
////
//// The second adapter that makes the transport seam real (the production
//// hackney adapter is the first). Serves scripted queues of responses in
//// call order so retry/fallback/circuit scenarios can be driven
//// deterministically with no network and no sleeping.
////
//// Both shapes are scripted: a sync queue (served in call order) and a
//// stream queue of `StreamScript`s. A committed stream script drives the
//// same two-phase relay protocol as the hackney adapter (report the head,
//// wait for `StartRelay`, forward chunks), so streaming retry/fallback and
//// relay forwarding are both testable in-process.

import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import pig_proxy/transport

/// Messages served by the in-memory transport actor.
pub type InMemoryMsg {
  TakeSync(reply_to: process.Subject(transport.TransportResponse))
  TakeStream(reply_to: process.Subject(StreamScript))
}

/// A scripted streaming outcome. `CommitStream` reports a committed head
/// and then forwards `chunks` followed by `terminal` once the relay is
/// started; `RejectStream`/`FailStream` report a non-committed head.
pub type StreamScript {
  CommitStream(
    status: Int,
    headers: List(#(String, String)),
    chunks: List(BitArray),
    terminal: StreamTerminal,
  )
  RejectStream(
    status: Int,
    headers: List(#(String, String)),
    body: BitArray,
  )
  FailStream(reason: String)
}

/// How a scripted committed stream ends.
pub type StreamTerminal {
  StreamDone
  StreamError(reason: String)
}

/// A script returned once the stream queue is exhausted.
pub const stream_exhausted_default = FailStream("in-memory stream queue exhausted")

type State {
  State(
    sync_queue: List(transport.TransportResponse),
    sync_exhausted: transport.TransportResponse,
    stream_queue: List(StreamScript),
    stream_exhausted: StreamScript,
  )
}

fn handle_message(state: State, msg: InMemoryMsg) {
  case msg {
    TakeSync(reply_to) ->
      case state.sync_queue {
        [next, ..rest] -> {
          process.send(reply_to, next)
          actor.continue(State(..state, sync_queue: rest))
        }
        [] -> {
          process.send(reply_to, state.sync_exhausted)
          actor.continue(state)
        }
      }
    TakeStream(reply_to) ->
      case state.stream_queue {
        [next, ..rest] -> {
          process.send(reply_to, next)
          actor.continue(State(..state, stream_queue: rest))
        }
        [] -> {
          process.send(reply_to, state.stream_exhausted)
          actor.continue(state)
        }
      }
  }
}

/// Start an in-memory transport serving `sync_queue` in call order. Once
/// the queue is exhausted it keeps returning `sync_exhausted`. No stream
/// scripts are configured (streaming would report a failure).
pub fn start(
  sync_queue: List(transport.TransportResponse),
  sync_exhausted: transport.TransportResponse,
) -> Result(process.Subject(InMemoryMsg), actor.StartError) {
  start_with(
    sync_queue,
    sync_exhausted,
    [],
    stream_exhausted_default,
  )
}

/// Start an in-memory transport serving `stream_queue` for streaming
/// attempts in call order. No sync scripts are configured.
pub fn start_stream(
  stream_queue: List(StreamScript),
  stream_exhausted: StreamScript,
) -> Result(process.Subject(InMemoryMsg), actor.StartError) {
  start_with(
    [],
    transport.TransportError("in-memory sync queue exhausted"),
    stream_queue,
    stream_exhausted,
  )
}

fn start_with(
  sync_queue,
  sync_exhausted,
  stream_queue,
  stream_exhausted,
) -> Result(process.Subject(InMemoryMsg), actor.StartError) {
  let result =
    State(sync_queue:, sync_exhausted:, stream_queue:, stream_exhausted:)
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
  transport.Transport(
    sync: fn(_req) {
      actor.call(subject, waiting: 5000, sending: fn(reply_to) { TakeSync(reply_to) })
    },
    stream: fn(_req) { stream_call(subject) },
  )
}

fn stream_call(subject: process.Subject(InMemoryMsg)) -> transport.StreamHead {
  // The relay (a spawned process) owns the run subject and reports the
  // head synchronously, mirroring the hackney adapter. This keeps the
  // commit decision out of the caller and the relay's receive valid.
  let head = process.new_subject()
  let _ = process.spawn(fn() { relay_loop(subject, head) })
  case process.receive(head, 5000) {
    Ok(h) -> h
    Error(Nil) -> transport.StreamFailure("in-memory stream head timeout")
  }
}

fn relay_loop(
  subject: process.Subject(InMemoryMsg),
  head: process.Subject(transport.StreamHead),
) -> Nil {
  let reply = process.new_subject()
  process.send(subject, TakeStream(reply))
  case process.receive(reply, 5000) {
    Error(Nil) ->
      process.send(head, transport.StreamFailure("in-memory script timeout"))
    Ok(RejectStream(status:, headers:, body:)) ->
      process.send(head, transport.StreamRejected(status:, headers:, body:))
    Ok(FailStream(reason:)) ->
      process.send(head, transport.StreamFailure(reason:))
    Ok(CommitStream(status:, headers:, chunks:, terminal:)) -> {
      let run = process.new_subject()
      process.send(head, transport.StreamCommitted(status:, headers:, run:))
      case process.receive(run, 2000) {
        Ok(transport.StartRelay(forward:)) -> {
          list.each(chunks, fn(c) {
            process.send(forward, transport.RelayChunk(c))
          })
          case terminal {
            StreamDone -> process.send(forward, transport.RelayDone)
            StreamError(reason:) ->
              process.send(forward, transport.RelayError(reason:))
          }
        }
        Error(Nil) -> Nil
      }
    }
  }
}
