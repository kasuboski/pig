//// Shared HTTP transport primitives.
////
//// A stream is opened as a lightweight process hand-off. The caller gets a
//// cancellable opaque handle immediately; the upstream head is delivered as
//// an event once the first byte commits a 2xx response. The relay never sends
//// body chunks to the sink before `start` and emits at most one terminal.

import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}

/// A single upstream request.
pub type Request {
  Request(
    method: String,
    url: String,
    headers: List(#(String, String)),
    body: String,
    timeout_ms: Int,
  )
}

/// The outcome of one buffered upstream request.
pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: BitArray)
  TransportError(reason: String)
}

/// Events delivered to a consumer of a stream handle.
pub type Event {
  /// A 2xx response committed after its first body byte (or an empty body).
  Committed(status: Int, headers: List(#(String, String)))
  /// A complete non-2xx response body, which is not committed for streaming.
  Rejected(status: Int, headers: List(#(String, String)), body: BitArray)
  /// A failure before a streaming response committed.
  Failed(reason: String)
  /// An ordered body chunk after the consumer starts the relay.
  Chunk(data: BitArray)
  /// The one successful terminal for a committed stream.
  Done
  /// The one failed terminal for a committed stream.
  StreamError(reason: String)
  /// The one cancellation terminal when cancellation can be delivered.
  Cancelled
}

/// Raw events produced by a stream adapter and consumed by the relay.
pub type SourceEvent {
  /// Provides a source-owned cancellation subject for adapters that can close
  /// their underlying connection before their process is killed.
  SourceReady(control: process.Subject(SourceControl))
  SourceHead(status: Int, headers: List(#(String, String)))
  SourceChunk(data: BitArray)
  SourceDone
  SourceError(reason: String)
}

/// Cancellation sent to a source adapter before its process is stopped.
pub type SourceControl {
  CancelSource
}

/// A synchronous adapter plus a streaming source adapter.
pub type Transport {
  Transport(
    sync: fn(Request) -> Response,
    stream: fn(Request, process.Subject(SourceEvent)) -> Nil,
  )
}

/// An opaque, idempotently cancellable stream handle.
pub opaque type StreamHandle {
  StreamHandle(
    events: process.Subject(Event),
    control: process.Subject(Command),
  )
}

type Command {
  Start(sink: process.Subject(Event))
  Cancel
}

type Phase {
  AwaitingHead
  AwaitingStart
  Running
}

type PendingTerminal {
  BufferedDone
  BufferedError(reason: String)
}

type RelayMessage {
  Source(message: SourceEvent)
  Command(message: Command)
  OwnerExited
  SinkExited
  SourceExited
  TimedOut
}

type RelayState {
  RelayState(
    phase: Phase,
    timeout_ms: Int,
    status: Option(#(Int, List(#(String, String)))),
    body_rev: List(BitArray),
    chunks_rev: List(BitArray),
    terminal: Option(PendingTerminal),
    sink: Option(process.Subject(Event)),
    sink_monitor: Option(process.Monitor),
    events: process.Subject(Event),
    source_events: process.Subject(SourceEvent),
    source_control: Option(process.Subject(SourceControl)),
    source: process.Pid,
    source_monitor: process.Monitor,
    control: process.Subject(Command),
    owner_monitor: process.Monitor,
  )
}

/// Perform one synchronous upstream request through a transport.
pub fn sync(transport: Transport, request: Request) -> Response {
  transport.sync(request)
}

/// Open a stream without performing upstream IO on the caller process.
///
/// The returned handle's events subject delivers `Committed`, `Rejected`, or
/// `Failed` for the head decision. Call `start` only after `Committed`; body
/// chunks and exactly one terminal then go to the sink.
pub fn open(transport: Transport, request: Request) -> StreamHandle {
  let events = process.new_subject()
  let ready = process.new_subject()
  let owner = process.self()
  let _ =
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      let source_events = process.new_subject()
      let source =
        process.spawn_unlinked(fn() { transport.stream(request, source_events) })
      let state =
        RelayState(
          phase: AwaitingHead,
          timeout_ms: request.timeout_ms,
          status: None,
          body_rev: [],
          chunks_rev: [],
          terminal: None,
          sink: None,
          sink_monitor: None,
          events:,
          source_events:,
          source_control: None,
          source:,
          source_monitor: process.monitor(source),
          control:,
          owner_monitor: process.monitor(owner),
        )
      process.send(ready, control)
      relay_loop(state)
    })
  let control = process.receive_forever(ready)
  StreamHandle(events:, control:)
}

/// Receive the next lifecycle event from a handle's head subject.
pub fn receive(handle: StreamHandle, timeout_ms: Int) -> Result(Event, Nil) {
  process.receive(handle.events, timeout_ms)
}

/// Get the head subject, primarily for consumers that use a selector.
pub fn events(handle: StreamHandle) -> process.Subject(Event) {
  handle.events
}

/// Start forwarding body chunks to `sink`.
///
/// Repeating the same start is harmless. A different sink gets a deterministic
/// pre-start terminal instead of being left waiting for a stream it cannot own.
pub fn start(handle: StreamHandle, sink: process.Subject(Event)) -> Nil {
  process.send(handle.control, Start(sink))
}

/// Cancel a stream. Repeated cancellation is harmless and produces no second
/// terminal event.
pub fn cancel(handle: StreamHandle) -> Nil {
  process.send(handle.control, Cancel)
}

fn relay_loop(state: RelayState) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(state.source_events, fn(message) { Source(message) })
    |> process.select_map(state.control, fn(message) { Command(message) })
  let selector =
    process.select_specific_monitor(selector, state.owner_monitor, fn(_) {
      OwnerExited
    })
  let selector =
    process.select_specific_monitor(selector, state.source_monitor, fn(_) {
      SourceExited
    })
  let selector = case state.sink_monitor {
    Some(monitor) ->
      process.select_specific_monitor(selector, monitor, fn(_) { SinkExited })
    None -> selector
  }
  case process.selector_receive(selector, state.timeout_ms) {
    Error(_) -> handle_message(state, TimedOut)
    Ok(message) -> handle_message(state, message)
  }
}

fn handle_message(state: RelayState, message: RelayMessage) -> Nil {
  case message {
    OwnerExited -> {
      // A live sink still needs a terminal even though its opener is gone.
      send_to_sink(state, Cancelled)
      stop_source(state)
      Nil
    }
    SinkExited -> {
      stop_source(state)
      Nil
    }
    SourceExited ->
      case state.terminal {
        Some(_) -> relay_loop(state)
        None ->
          case state.source_control {
            Some(_) -> handle_source_exited(state)
            None -> handle_source_exited(state)
          }
      }
    TimedOut -> {
      let reason = case state.phase {
        AwaitingHead -> "timeout waiting for upstream head"
        AwaitingStart -> "timeout waiting for consumer start"
        Running -> "stream timeout"
      }
      terminal(state, StreamError(reason), Failed(reason))
    }
    Command(command) -> handle_command(state, command)
    Source(source_message) -> handle_source(state, source_message)
  }
}

fn handle_command(state: RelayState, command: Command) -> Nil {
  case command {
    Cancel -> handle_cancel(state)
    Start(sink) -> handle_start(state, sink)
  }
}

fn handle_cancel(state: RelayState) -> Nil {
  stop_source(state)
  case state.phase {
    AwaitingHead -> process.send(state.events, Cancelled)
    _ -> send_terminal(state, Cancelled)
  }
  Nil
}

fn handle_start(state: RelayState, sink: process.Subject(Event)) -> Nil {
  case state.sink {
    None -> handle_start_without_sink(state, sink)
    Some(existing) -> handle_start_with_sink(state, existing, sink)
  }
}

fn handle_start_without_sink(
  state: RelayState,
  sink: process.Subject(Event),
) -> Nil {
  handle_start_phase(set_sink(state, sink))
}

fn handle_start_with_sink(
  state: RelayState,
  existing: process.Subject(Event),
  sink: process.Subject(Event),
) -> Nil {
  case existing == sink {
    True -> handle_same_sink(state)
    False -> {
      process.send(sink, Failed("stream already has a sink"))
      relay_loop(state)
    }
  }
}

fn handle_same_sink(state: RelayState) -> Nil {
  case state.phase {
    AwaitingStart -> maybe_start(state)
    _ -> relay_loop(state)
  }
}

fn handle_start_phase(state: RelayState) -> Nil {
  case state.phase {
    AwaitingHead -> relay_loop(state)
    AwaitingStart -> maybe_start(state)
    Running -> relay_loop(state)
  }
}

fn handle_source_exited(state: RelayState) -> Nil {
  // A normal source can exit immediately after sending its terminal. Drain
  // one queued source event before treating the monitor notification as a
  // failure; message order keeps the terminal ahead of the exit signal.
  case process.receive(state.source_events, 0) {
    Ok(SourceReady(control)) ->
      handle_source_exited(RelayState(..state, source_control: Some(control)))
    Ok(source) -> handle_source(state, source)
    Error(_) ->
      handle_source_terminal(
        state,
        BufferedError("upstream source exited unexpectedly"),
      )
  }
}

fn handle_source(state: RelayState, source: SourceEvent) -> Nil {
  case source {
    SourceReady(control) ->
      relay_loop(RelayState(..state, source_control: Some(control)))
    SourceHead(status:, headers:) -> handle_source_head(state, status, headers)
    SourceChunk(data) -> handle_source_chunk(state, data)
    SourceDone -> handle_source_terminal(state, BufferedDone)
    SourceError(reason) -> handle_source_terminal(state, BufferedError(reason))
  }
}

fn handle_source_head(
  state: RelayState,
  status: Int,
  headers: List(#(String, String)),
) -> Nil {
  case state.phase, state.status {
    AwaitingHead, None ->
      relay_loop(RelayState(..state, status: Some(#(status, headers))))
    _, _ ->
      terminal(
        state,
        StreamError("duplicate upstream head"),
        Failed("duplicate upstream head"),
      )
  }
}

fn handle_source_chunk(state: RelayState, data: BitArray) -> Nil {
  case state.phase, state.status {
    AwaitingHead, Some(#(status, headers)) ->
      case is_success(status) {
        True -> {
          let committed =
            RelayState(..state, phase: AwaitingStart, chunks_rev: [
              data,
              ..state.chunks_rev
            ])
          process.send(state.events, Committed(status:, headers:))
          maybe_start(committed)
        }
        False ->
          relay_loop(RelayState(..state, body_rev: [data, ..state.body_rev]))
      }
    AwaitingHead, None ->
      terminal(
        state,
        StreamError("upstream body arrived before head"),
        Failed("upstream body arrived before head"),
      )
    AwaitingStart, _ ->
      relay_loop(RelayState(..state, chunks_rev: [data, ..state.chunks_rev]))
    Running, _ -> {
      send_to_sink(state, Chunk(data:))
      relay_loop(state)
    }
  }
}

fn handle_source_terminal(
  state: RelayState,
  source_terminal: PendingTerminal,
) -> Nil {
  case state.phase {
    AwaitingHead -> handle_head_terminal(state, source_terminal)
    AwaitingStart ->
      maybe_start(RelayState(..state, terminal: Some(source_terminal)))
    Running -> handle_running_terminal(state, source_terminal)
  }
}

fn handle_head_terminal(
  state: RelayState,
  source_terminal: PendingTerminal,
) -> Nil {
  case state.status {
    Some(#(status, headers)) ->
      handle_head_terminal_with_status(state, status, headers, source_terminal)
    None -> handle_head_without_status(state, source_terminal)
  }
}

fn handle_head_terminal_with_status(
  state: RelayState,
  status: Int,
  headers: List(#(String, String)),
  source_terminal: PendingTerminal,
) -> Nil {
  case is_success(status) {
    True -> handle_successful_head(state, status, headers, source_terminal)
    False -> handle_rejected_head(state, status, headers, source_terminal)
  }
}

fn handle_successful_head(
  state: RelayState,
  status: Int,
  headers: List(#(String, String)),
  source_terminal: PendingTerminal,
) -> Nil {
  case source_terminal {
    BufferedDone -> {
      let committed =
        RelayState(..state, phase: AwaitingStart, terminal: Some(BufferedDone))
      process.send(state.events, Committed(status:, headers:))
      maybe_start(committed)
    }
    BufferedError(reason) ->
      terminal(state, StreamError(reason), Failed(reason))
  }
}

fn handle_rejected_head(
  state: RelayState,
  status: Int,
  headers: List(#(String, String)),
  source_terminal: PendingTerminal,
) -> Nil {
  case source_terminal {
    BufferedDone -> {
      let body = bit_array.concat(list.reverse(state.body_rev))
      process.send(state.events, Rejected(status:, headers:, body:))
      stop_source(state)
      Nil
    }
    BufferedError(reason) ->
      terminal(state, StreamError(reason), Failed(reason))
  }
}

fn handle_head_without_status(
  state: RelayState,
  source_terminal: PendingTerminal,
) -> Nil {
  case source_terminal {
    BufferedDone ->
      terminal(
        state,
        StreamError("upstream ended before response head"),
        Failed("upstream ended before response head"),
      )
    BufferedError(reason) ->
      terminal(state, StreamError(reason), Failed(reason))
  }
}

fn handle_running_terminal(
  state: RelayState,
  source_terminal: PendingTerminal,
) -> Nil {
  case source_terminal {
    BufferedDone -> {
      send_to_sink(state, Done)
      stop_source(state)
      Nil
    }
    BufferedError(reason) -> {
      send_to_sink(state, StreamError(reason:))
      stop_source(state)
      Nil
    }
  }
}

fn set_sink(state: RelayState, sink: process.Subject(Event)) -> RelayState {
  RelayState(
    ..state,
    sink: Some(sink),
    sink_monitor: case process.subject_owner(sink) {
      Ok(owner) -> Some(process.monitor(owner))
      Error(_) -> None
    },
  )
}

fn maybe_start(state: RelayState) -> Nil {
  case state.phase, state.sink {
    AwaitingStart, Some(sink) -> {
      list.each(list.reverse(state.chunks_rev), fn(data) {
        process.send(sink, Chunk(data:))
      })
      case state.terminal {
        None -> relay_loop(RelayState(..state, phase: Running, chunks_rev: []))
        Some(BufferedDone) -> {
          process.send(sink, Done)
          stop_source(state)
          Nil
        }
        Some(BufferedError(reason)) -> {
          process.send(sink, StreamError(reason:))
          stop_source(state)
          Nil
        }
      }
    }
    _, _ -> relay_loop(state)
  }
}

fn send_to_sink(state: RelayState, event: Event) -> Nil {
  case state.sink {
    Some(sink) -> process.send(sink, event)
    None -> process.send(state.events, event)
  }
}

fn send_terminal(state: RelayState, event: Event) -> Nil {
  send_to_sink(state, event)
}

fn terminal(state: RelayState, committed: Event, precommit: Event) -> Nil {
  case state.phase {
    AwaitingHead -> process.send(state.events, precommit)
    _ -> send_terminal(state, committed)
  }
  stop_source(state)
}

fn stop_source(state: RelayState) -> Nil {
  case state.source_control {
    // The adapter owns the upstream handle and can perform the real close.
    Some(control) -> process.send(control, CancelSource)
    // Before SourceReady there is no safe way to reach the adapter. The
    // source process is the cleanup boundary in that narrow race.
    None -> process.kill(state.source)
  }
}

fn is_success(status: Int) -> Bool {
  status >= 200 && status < 300
}
