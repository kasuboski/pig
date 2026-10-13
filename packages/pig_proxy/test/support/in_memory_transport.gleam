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
//// wait for `start`, forward chunks), so streaming retry/fallback and
//// relay forwarding are both testable in-process.
////
//// The adapter also records outgoing `Request`s in attempt order
//// (sync or stream), so tests can assert on the auth/URL that execution
//// actually put on the wire — closing the auth-wiring gap without a socket.

import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import pig_transport as transport

/// Messages served by the in-memory transport actor.
pub type InMemoryMsg {
  TakeSync(
    request: transport.Request,
    reply_to: process.Subject(transport.Response),
  )
  TakeStream(
    request: transport.Request,
    reply_to: process.Subject(StreamScript),
  )
  GetLastRequest(reply_to: process.Subject(Option(transport.Request)))
  GetRequests(reply_to: process.Subject(List(transport.Request)))
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
  RejectStream(status: Int, headers: List(#(String, String)), body: BitArray)
  FailStream(reason: String)
}

/// How a scripted committed stream ends.
pub type StreamTerminal {
  StreamDone
  StreamError(reason: String)
}

/// A script returned once the stream queue is exhausted.
pub const stream_exhausted_default = FailStream(
  "in-memory stream queue exhausted",
)

type State {
  State(
    sync_queue: List(transport.Response),
    sync_exhausted: transport.Response,
    stream_queue: List(StreamScript),
    stream_exhausted: StreamScript,
    reversed_requests: List(transport.Request),
  )
}

fn handle_message(state: State, msg: InMemoryMsg) {
  case msg {
    TakeSync(request:, reply_to:) -> {
      let state =
        State(..state, reversed_requests: [request, ..state.reversed_requests])
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
    }
    TakeStream(request:, reply_to:) -> {
      let state =
        State(..state, reversed_requests: [request, ..state.reversed_requests])
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
    GetLastRequest(reply_to:) -> {
      let last = case state.reversed_requests {
        [request, ..] -> Some(request)
        [] -> None
      }
      process.send(reply_to, last)
      actor.continue(state)
    }
    GetRequests(reply_to:) -> {
      process.send(reply_to, list.reverse(state.reversed_requests))
      actor.continue(state)
    }
  }
}

/// Start an in-memory transport serving `sync_queue` in call order. Once
/// the queue is exhausted it keeps returning `sync_exhausted`. No stream
/// scripts are configured (streaming would report a failure).
pub fn start(
  sync_queue: List(transport.Response),
  sync_exhausted: transport.Response,
) -> Result(process.Subject(InMemoryMsg), actor.StartError) {
  start_with(sync_queue, sync_exhausted, [], stream_exhausted_default)
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

/// Start both scripted shapes for shared orchestration contract matrices.
pub fn start_with(
  sync_queue,
  sync_exhausted,
  stream_queue,
  stream_exhausted,
) -> Result(process.Subject(InMemoryMsg), actor.StartError) {
  let result =
    State(
      sync_queue:,
      sync_exhausted:,
      stream_queue:,
      stream_exhausted:,
      reversed_requests: [],
    )
    |> actor.new
    |> actor.on_message(handle_message)
    |> actor.start
  case result {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Build a `transport.Transport` backed by an in-memory actor.
pub fn transport(subject: process.Subject(InMemoryMsg)) -> transport.Transport {
  transport.Transport(
    sync: fn(req) {
      actor.call(subject, waiting: 5000, sending: fn(reply_to) {
        TakeSync(request: req, reply_to:)
      })
    },
    stream: fn(req, events) { stream_call(subject, req, events) },
  )
}

/// The most recent outgoing request the adapter saw (sync or stream), or
/// `None` if it has received none. Lets tests assert on the auth/URL that
/// execution placed on the wire.
pub fn last_request(
  subject: process.Subject(InMemoryMsg),
) -> Option(transport.Request) {
  actor.call(subject, waiting: 5000, sending: fn(reply_to) {
    GetLastRequest(reply_to:)
  })
}

/// All outgoing requests in physical attempt order, including exhausted scripts.
pub fn requests(
  subject: process.Subject(InMemoryMsg),
) -> List(transport.Request) {
  actor.call(subject, waiting: 5000, sending: fn(reply_to) {
    GetRequests(reply_to:)
  })
}

fn stream_call(
  subject: process.Subject(InMemoryMsg),
  request: transport.Request,
  events: process.Subject(transport.SourceEvent),
) -> Nil {
  let reply = process.new_subject()
  process.send(subject, TakeStream(request:, reply_to: reply))
  case process.receive(reply, 5000) {
    Error(_) ->
      process.send(events, transport.SourceError("in-memory script timeout"))
    Ok(RejectStream(status:, headers:, body:)) -> {
      process.send(events, transport.SourceHead(status:, headers:))
      process.send(events, transport.SourceChunk(body))
      process.send(events, transport.SourceDone)
    }
    Ok(FailStream(reason:)) ->
      process.send(events, transport.SourceError(reason:))
    Ok(CommitStream(status:, headers:, chunks:, terminal:)) -> {
      process.send(events, transport.SourceHead(status:, headers:))
      list.each(chunks, fn(chunk) {
        process.send(events, transport.SourceChunk(chunk))
      })
      case terminal {
        StreamDone -> process.send(events, transport.SourceDone)
        StreamError(reason:) ->
          process.send(events, transport.SourceError(reason:))
      }
    }
  }
  Nil
}
