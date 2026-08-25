//// Deterministic contract tests for the shared stream lifecycle.

import gleam/erlang/process
import gleam/list
import gleeunit
import pig_transport

pub fn main() -> Nil {
  gleeunit.main()
}

fn request() -> pig_transport.Request {
  pig_transport.Request("POST", "http://example.test/v1", [], "{}", 1000)
}

fn scripted(
  events: List(pig_transport.SourceEvent),
) -> pig_transport.Transport {
  pig_transport.Transport(
    sync: fn(_) { pig_transport.TransportError("unused") },
    stream: fn(_, subject) {
      let control = process.new_subject()
      process.send(subject, pig_transport.SourceReady(control))
      list.each(events, fn(event) { process.send(subject, event) })
    },
  )
}

fn receive_event(handle: pig_transport.StreamHandle) -> pig_transport.Event {
  let assert Ok(event) = pig_transport.receive(handle, 1000)
  event
}

fn receive_sink(
  subject: process.Subject(pig_transport.Event),
) -> pig_transport.Event {
  let assert Ok(event) = process.receive(subject, 1000)
  event
}

pub fn open_delivers_head_without_blocking_on_body_test() {
  let handle =
    pig_transport.open(
      scripted([
        pig_transport.SourceHead(200, []),
        pig_transport.SourceChunk(<<"first">>),
      ]),
      request(),
    )
  let assert pig_transport.Committed(200, []) = receive_event(handle)
}

pub fn committed_stream_sends_no_bytes_before_start_test() {
  let handle =
    pig_transport.open(
      scripted([
        pig_transport.SourceHead(200, []),
        pig_transport.SourceChunk(<<"first">>),
        pig_transport.SourceDone,
      ]),
      request(),
    )
  let assert pig_transport.Committed(..) = receive_event(handle)
  let sink = process.new_subject()
  assert Error(Nil) == process.receive(sink, 0)
  pig_transport.start(handle, sink)
  let assert pig_transport.Chunk(<<"first">>) = receive_sink(sink)
  let assert pig_transport.Done = receive_sink(sink)
}

pub fn chunks_are_ordered_and_have_exactly_one_terminal_test() {
  let handle =
    pig_transport.open(
      scripted([
        pig_transport.SourceHead(200, []),
        pig_transport.SourceChunk(<<"a">>),
        pig_transport.SourceChunk(<<"b">>),
        pig_transport.SourceDone,
      ]),
      request(),
    )
  let assert pig_transport.Committed(..) = receive_event(handle)
  let sink = process.new_subject()
  pig_transport.start(handle, sink)
  let assert pig_transport.Chunk(<<"a">>) = receive_sink(sink)
  let assert pig_transport.Chunk(<<"b">>) = receive_sink(sink)
  let assert pig_transport.Done = receive_sink(sink)
  assert Error(Nil) == process.receive(sink, 0)
}

pub fn non_2xx_body_is_complete_before_rejection_test() {
  let handle =
    pig_transport.open(
      scripted([
        pig_transport.SourceHead(503, [#("retry-after", "1")]),
        pig_transport.SourceChunk(<<"part-1">>),
        pig_transport.SourceChunk(<<"-part-2">>),
        pig_transport.SourceDone,
      ]),
      request(),
    )
  let assert pig_transport.Rejected(503, headers, body) = receive_event(handle)
  assert headers == [#("retry-after", "1")]
  assert body == <<"part-1-part-2">>
  assert Error(Nil) == pig_transport.receive(handle, 0)
}

pub fn cancellation_before_head_is_idempotent_test() {
  let blocker = process.new_subject()
  let transport =
    pig_transport.Transport(
      sync: fn(_) { pig_transport.TransportError("unused") },
      stream: fn(_, _) { process.receive_forever(blocker) },
    )
  let handle = pig_transport.open(transport, request())
  pig_transport.cancel(handle)
  pig_transport.cancel(handle)
  let assert pig_transport.Cancelled = receive_event(handle)
  assert Error(Nil) == pig_transport.receive(handle, 0)
}

pub fn cancellation_before_relay_start_is_terminal_and_byte_free_test() {
  let handle =
    pig_transport.open(
      scripted([
        pig_transport.SourceHead(200, []),
        pig_transport.SourceChunk(<<"held">>),
        pig_transport.SourceDone,
      ]),
      request(),
    )
  let assert pig_transport.Committed(..) = receive_event(handle)
  pig_transport.cancel(handle)
  pig_transport.cancel(handle)
  let assert pig_transport.Cancelled = receive_event(handle)
  assert Error(Nil) == pig_transport.receive(handle, 0)
}

pub fn cancellation_during_relay_has_one_terminal_test() {
  let blocker = process.new_subject()
  let transport =
    pig_transport.Transport(
      sync: fn(_) { pig_transport.TransportError("unused") },
      stream: fn(_, subject) {
        process.send(subject, pig_transport.SourceHead(200, []))
        process.send(subject, pig_transport.SourceChunk(<<"live">>))
        process.receive_forever(blocker)
      },
    )
  let handle = pig_transport.open(transport, request())
  let assert pig_transport.Committed(..) = receive_event(handle)
  let sink = process.new_subject()
  pig_transport.start(handle, sink)
  let assert pig_transport.Chunk(<<"live">>) = receive_sink(sink)
  pig_transport.cancel(handle)
  pig_transport.cancel(handle)
  let assert pig_transport.Cancelled = receive_sink(sink)
  assert Error(Nil) == process.receive(sink, 0)
}

pub fn source_error_before_first_byte_does_not_commit_test() {
  let handle =
    pig_transport.open(
      scripted([
        pig_transport.SourceHead(200, []),
        pig_transport.SourceError("before first byte"),
      ]),
      request(),
    )
  let assert pig_transport.Failed("before first byte") = receive_event(handle)
  assert Error(Nil) == pig_transport.receive(handle, 0)
}

pub fn owner_exit_cleans_up_upstream_source_test() {
  let owner_ready = process.new_subject()
  let source_pid = process.new_subject()
  let transport =
    pig_transport.Transport(
      sync: fn(_) { pig_transport.TransportError("unused") },
      stream: fn(_, events) {
        process.send(source_pid, process.self())
        process.send(events, pig_transport.SourceHead(200, []))
        process.sleep_forever()
      },
    )
  let owner =
    process.spawn_unlinked(fn() {
      let _ = pig_transport.open(transport, request())
      process.send(owner_ready, process.self())
      process.sleep_forever()
    })
  let assert Ok(source) = process.receive(source_pid, 1000)
  let assert Ok(_) = process.receive(owner_ready, 1000)
  let source_monitor = process.monitor(source)
  process.kill(owner)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(source_monitor, fn(_) { Nil })
  let assert Ok(Nil) = process.selector_receive(selector, 1000)
}

pub fn sink_exit_cleans_up_upstream_source_test() {
  let sink_info = process.new_subject()
  let source_pid = process.new_subject()
  let received = process.new_subject()
  let transport =
    pig_transport.Transport(
      sync: fn(_) { pig_transport.TransportError("unused") },
      stream: fn(_, events) {
        process.send(source_pid, process.self())
        process.send(events, pig_transport.SourceHead(200, []))
        process.send(events, pig_transport.SourceChunk(<<"one">>))
        process.sleep_forever()
      },
    )
  let handle = pig_transport.open(transport, request())
  let assert pig_transport.Committed(..) = receive_event(handle)
  let sink_owner =
    process.spawn_unlinked(fn() {
      let sink = process.new_subject()
      process.send(sink_info, #(sink, process.self()))
      let _ = process.receive(sink, 1000)
      process.send(received, Nil)
    })
  let assert Ok(source) = process.receive(source_pid, 1000)
  let assert Ok(#(sink, owner)) = process.receive(sink_info, 1000)
  let source_monitor = process.monitor(source)
  assert owner == sink_owner
  pig_transport.start(handle, sink)
  let assert Ok(Nil) = process.receive(received, 1000)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(source_monitor, fn(_) { Nil })
  let assert Ok(Nil) = process.selector_receive(selector, 1000)
}

pub fn request_timeout_is_available_to_stream_adapter_test() {
  let seen = process.new_subject()
  let transport =
    pig_transport.Transport(
      sync: fn(_) { pig_transport.TransportError("unused") },
      stream: fn(request, events) {
        process.send(seen, request.timeout_ms)
        process.send(events, pig_transport.SourceError("stop"))
      },
    )
  let handle =
    pig_transport.open(
      transport,
      pig_transport.Request("GET", "http://example.test", [], "", 37),
    )
  let assert Ok(37) = process.receive(seen, 1000)
  let assert pig_transport.Failed("stop") = receive_event(handle)
}

pub fn graceful_cancel_closes_source_once_test() {
  let source_info = process.new_subject()
  let closed = process.new_subject()
  let transport =
    pig_transport.Transport(
      sync: fn(_) { pig_transport.TransportError("unused") },
      stream: fn(_, events) {
        let control = process.new_subject()
        process.send(source_info, #(process.self(), control))
        process.send(events, pig_transport.SourceReady(control))
        process.send(events, pig_transport.SourceHead(200, []))
        process.send(events, pig_transport.SourceChunk(<<"live">>))
        let assert Ok(pig_transport.CancelSource) =
          process.receive(control, 1000)
        process.send(closed, Nil)
      },
    )
  let handle = pig_transport.open(transport, request())
  let assert Ok(#(source, _control)) = process.receive(source_info, 1000)
  let source_monitor = process.monitor(source)
  let assert pig_transport.Committed(..) = receive_event(handle)
  let sink = process.new_subject()
  pig_transport.start(handle, sink)
  let assert pig_transport.Chunk(<<"live">>) = receive_sink(sink)
  pig_transport.cancel(handle)
  pig_transport.cancel(handle)
  let assert pig_transport.Cancelled = receive_sink(sink)
  let assert Ok(Nil) = process.receive(closed, 1000)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(source_monitor, fn(_) { Nil })
  let assert Ok(Nil) = process.selector_receive(selector, 1000)
  assert Error(Nil) == process.receive(sink, 0)
}

pub fn second_start_gets_a_terminal_test() {
  let blocker = process.new_subject()
  let transport =
    pig_transport.Transport(
      sync: fn(_) { pig_transport.TransportError("unused") },
      stream: fn(_, events) {
        process.send(events, pig_transport.SourceHead(200, []))
        process.send(events, pig_transport.SourceChunk(<<"one">>))
        process.receive_forever(blocker)
      },
    )
  let handle = pig_transport.open(transport, request())
  let assert pig_transport.Committed(..) = receive_event(handle)
  let first_sink = process.new_subject()
  let second_sink = process.new_subject()
  pig_transport.start(handle, first_sink)
  let assert pig_transport.Chunk(<<"one">>) = receive_sink(first_sink)
  pig_transport.start(handle, second_sink)
  let assert pig_transport.Failed("stream already has a sink") =
    receive_sink(second_sink)
  pig_transport.cancel(handle)
  let assert pig_transport.Cancelled = receive_sink(first_sink)
}

pub fn owner_exit_notifies_live_sink_before_cleanup_test() {
  let handle_info = process.new_subject()
  let blocker = process.new_subject()
  let transport =
    pig_transport.Transport(
      sync: fn(_) { pig_transport.TransportError("unused") },
      stream: fn(_, events) {
        process.send(events, pig_transport.SourceHead(200, []))
        process.send(events, pig_transport.SourceChunk(<<"one">>))
        process.receive_forever(blocker)
      },
    )
  let owner =
    process.spawn_unlinked(fn() {
      let handle = pig_transport.open(transport, request())
      let assert pig_transport.Committed(..) = receive_event(handle)
      process.send(handle_info, handle)
      process.sleep_forever()
    })
  let assert Ok(handle) = process.receive(handle_info, 1000)
  let sink = process.new_subject()
  pig_transport.start(handle, sink)
  let assert pig_transport.Chunk(<<"one">>) = receive_sink(sink)
  process.kill(owner)
  let assert pig_transport.Cancelled = receive_sink(sink)
  assert Error(Nil) == process.receive(sink, 0)
}

pub fn source_failure_before_terminal_is_reported_test() {
  let transport =
    pig_transport.Transport(
      sync: fn(_) { pig_transport.TransportError("unused") },
      stream: fn(_, events) {
        let control = process.new_subject()
        process.send(events, pig_transport.SourceReady(control))
        process.kill(process.self())
      },
    )
  let handle = pig_transport.open(transport, request())
  let assert pig_transport.Failed("upstream source exited unexpectedly") =
    receive_event(handle)
}
