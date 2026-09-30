//// Supervised per-request tracing. The owner is activated only after its
//// supervisor has registered it; spans never belong to a vulnerable handler.
//// Buffered completion is response construction, streaming completion is the
//// last application body-send/terminal callback, not Mist's private terminator.

import gleam/bit_array
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/factory_supervisor as factory
import gleam/otp/supervision
import gleam/result
import otel/context.{type Context}
import pig_otel
import pig_proxy/trace_metadata
import pig_transport as transport

/// Handle to one surviving owner; not a span or an SDK lifecycle handle.
pub type Owner

/// Child argument captured before body reading. The caller is monitored by
/// the owner before activation, even if it dies during child registration.
pub type Registration {
  Registration(
    caller: process.Pid,
    policy: pig_otel.Policy,
    parent: Context,
    route: String,
  )
}

/// The factory name carried by server runtime state.
pub type Owners =
  process.Name(factory.Message(Registration, Owner))

/// Chunk loop messages; receipt is distinct from upstream body forwarding.
pub type ChunkMessage {
  Receipt
  Body(transport.Event)
}

/// Owner commands. Calls acknowledge all lifecycle transitions.
pub type Command {
  Activate
  ServerContext
  BeginInference(api: pig_otel.Api, provider: Option(String), model: String)
  BeginAttempt(target: String)
  OpenStream(
    adapter: transport.Transport,
    request: transport.Request,
    head: process.Subject(transport.Event),
  )
  SyncTerminal(response: transport.Response)
  AbortAttempt
  SelectStream(target: String, provider: String, status: Int)
  LogicalTerminal(
    outcome: pig_otel.Outcome,
    metadata: trace_metadata.Observed,
    status: Int,
  )
  Bind(sink: process.Subject(ChunkMessage))
  Accepted
  HandoffReceipt
  Downstream(outcome: pig_otel.Outcome)
  Shutdown
  Snapshot
}

/// A deterministic snapshot is useful for lifecycle acceptance tests.
pub type View {
  View(
    server_live: Bool,
    logical_live: Bool,
    attempt_live: Bool,
    accepted: Bool,
    handed_off: Bool,
    attempt_count: Int,
    metadata: trace_metadata.Observed,
  )
}

/// Typed acknowledgement; context crosses every actual callback boundary.
pub type Reply {
  Ack
  Current(Context)
  Opened(transport.StreamHandle)
  Inspect(View)
}

type Handoff {
  AwaitingChunk
  Bound(process.Subject(ChunkMessage))
  SetupAccepted(process.Subject(ChunkMessage))
  HandedOff(process.Subject(ChunkMessage))
}

/// State belongs solely to the supervised owner process.
pub opaque type State {
  State(
    registration: Registration,
    backend: pig_otel.Backend,
    server: Option(pig_otel.Span),
    logical: Option(pig_otel.Span),
    logical_closed: Bool,
    attempt: Option(pig_otel.Span),
    api: pig_otel.Api,
    metadata: trace_metadata.Observed,
    framer: trace_metadata.Framer,
    upstream: Option(pig_otel.Outcome),
    downstream: Option(pig_otel.Outcome),
    abort: Option(pig_otel.Outcome),
    committed: Bool,
    handle: Option(transport.StreamHandle),
    handoff: Handoff,
    head: Option(process.Subject(transport.Event)),
    pending_terminal: Option(transport.Event),
    count: Int,
    attempt_status: Int,
    start_time: Int,
    inference_start_time: Int,
    attempt_start_time: Int,
    first_chunk: Bool,
    first_send: Bool,
  )
}

/// Marker is defined in the consumer application, never in pig_otel.
fn application_marker() -> Nil {
  Nil
}

/// Temporary children are not restarted with stale span handles.
pub fn supervisor(
  name: Owners,
) -> supervision.ChildSpecification(factory.Supervisor(Registration, Owner)) {
  factory.worker_child(start_owner)
  |> factory.restart_strategy(supervision.Temporary)
  |> factory.named(name)
  |> factory.supervised
}

/// Create and activate only after the factory's registration acknowledgement.
pub fn register(
  name: Owners,
  policy: pig_otel.Policy,
  headers: List(#(String, String)),
  route: String,
) -> Owner {
  let boot =
    Registration(process.self(), policy, pig_otel.ingress(headers), route)
  let assert Ok(started) = factory.start_child(factory.get_by_name(name), boot)
  let _ = call(started.data, Activate)
  started.data
}

@external(erlang, "pig_proxy_tracing_ffi", "start_owner")
fn start_owner(registration: Registration) -> actor.StartResult(Owner)

/// Calls fail if the owner is gone, rather than permitting unowned work.
@external(erlang, "pig_proxy_tracing_ffi", "call")
pub fn call(owner: Owner, command: Command) -> Reply

/// Send successful application-send timing without blocking on transport IO.
@external(erlang, "pig_proxy_tracing_ffi", "sent")
pub fn sent(owner: Owner) -> Nil

@external(erlang, "pig_proxy_tracing_ffi", "watch_subject")
fn watch_subject(generation: Int) -> process.Subject(transport.SourceEvent)

@external(erlang, "pig_proxy_stream_watch_ffi", "stream")
fn watch_stream(
  request: transport.Request,
  relay: process.Subject(transport.SourceEvent),
  watch: process.Subject(transport.SourceEvent),
  callback: fn(transport.Request, process.Subject(transport.SourceEvent)) -> Nil,
) -> Nil

fn open_watched(
  adapter: transport.Transport,
  request: transport.Request,
  watch: process.Subject(transport.SourceEvent),
) -> transport.StreamHandle {
  let watched =
    transport.Transport(..adapter, stream: fn(req, relay) {
      watch_stream(req, relay, watch, adapter.stream)
    })
  transport.open(watched, request)
}

@external(erlang, "pig_proxy_tracing_ffi", "sink_subject")
fn sink_subject(generation: Int) -> process.Subject(transport.Event)

@external(erlang, "pig_proxy_tracing_ffi", "track_head")
fn track_head(subject: process.Subject(transport.Event), generation: Int) -> Nil

@external(erlang, "pig_proxy_tracing_ffi", "now_ms")
fn now_ms() -> Int

/// Initial state contains no live span: supervisor registration comes first.
pub fn initialise(registration: Registration) -> State {
  State(
    registration:,
    backend: pig_otel.disabled(),
    server: None,
    logical: None,
    logical_closed: False,
    attempt: None,
    api: pig_otel.Custom,
    metadata: trace_metadata.empty(),
    framer: trace_metadata.new_framer(),
    upstream: None,
    downstream: None,
    abort: None,
    committed: False,
    handle: None,
    handoff: AwaitingChunk,
    head: None,
    pending_terminal: None,
    count: 0,
    attempt_status: 0,
    start_time: now_ms(),
    inference_start_time: now_ms(),
    attempt_start_time: now_ms(),
    first_chunk: False,
    first_send: False,
  )
}

@external(erlang, "binary", "copy")
fn copy_string(value: String) -> String

fn bounded_model(model: String) -> Option(String) {
  case
    model != "unknown"
    && bit_array.byte_size(bit_array.from_string(model)) <= 256
  {
    True -> Some(copy_string(model))
    False -> None
  }
}

fn parent(state: State) -> Context {
  case state.logical, state.server {
    Some(span), _ -> pig_otel.context(span)
    _, Some(span) -> pig_otel.context(span)
    _, _ -> state.registration.parent
  }
}

/// All mutation and terminal arbitration runs in the surviving owner.
pub fn command(state: State, command: Command) -> #(State, Reply) {
  case command, state.server, state.logical, state.attempt {
    Activate, Some(span), _, _ -> #(state, Current(pig_otel.context(span)))
    BeginInference(..), _, Some(span), _ -> #(
      state,
      Current(pig_otel.context(span)),
    )
    BeginAttempt(_), _, _, Some(span) -> #(
      state,
      Current(pig_otel.context(span)),
    )
    LogicalTerminal(..), _, _, _ if state.logical_closed -> #(state, Ack)
    BeginInference(..), _, _, _ if state.logical_closed -> #(state, Ack)
    BeginAttempt(_), _, _, _ if state.logical_closed -> #(state, Ack)
    SyncTerminal(_), _, _, _ if state.upstream != None -> #(state, Ack)
    _, _, _, _ -> perform_command(state, command)
  }
}

fn perform_command(state: State, command: Command) -> #(State, Reply) {
  case command {
    ServerContext -> {
      let ctx = case state.server {
        Some(span) -> pig_otel.context(span)
        None -> state.registration.parent
      }
      #(state, Current(ctx))
    }
    Activate -> {
      let backend =
        pig_otel.backend(state.registration.policy, application_marker)
      let span =
        pig_otel.start(
          backend,
          state.registration.parent,
          pig_otel.HttpServer(state.registration.route),
        )
      let next = State(..state, backend:, server: Some(span))
      #(next, Current(pig_otel.context(span)))
    }
    BeginInference(api, provider, model) -> {
      let logical =
        pig_otel.start(
          state.backend,
          parent(state),
          pig_otel.Inference(api, provider, bounded_model(model)),
        )
      #(
        State(
          ..state,
          logical: Some(logical),
          api:,
          inference_start_time: now_ms(),
        ),
        Current(pig_otel.context(logical)),
      )
    }
    BeginAttempt(target) -> {
      let span =
        pig_otel.start(
          state.backend,
          parent(state),
          pig_otel.HttpAttempt(target),
        )
      pig_otel.annotate(span, [
        pig_otel.int_attribute("pig.proxy.attempt", state.count + 1),
      ])
      #(
        State(
          ..state,
          attempt: Some(span),
          metadata: trace_metadata.empty(),
          framer: trace_metadata.new_framer(),
          upstream: None,
          abort: None,
          pending_terminal: None,
          count: state.count + 1,
          attempt_status: 0,
          attempt_start_time: now_ms(),
          first_chunk: False,
        ),
        Current(pig_otel.context(span)),
      )
    }
    OpenStream(adapter, request, head) -> {
      let ctx = case state.attempt {
        Some(span) -> pig_otel.context(span)
        None -> parent(state)
      }
      let handle =
        context.with_context(ctx, fn() {
          open_watched(adapter, request, watch_subject(state.count))
        })
      track_head(transport.events(handle), state.count)
      #(State(..state, handle: Some(handle), head: Some(head)), Opened(handle))
    }
    SyncTerminal(response) -> {
      let #(outcome, metadata, status) = case response {
        transport.TransportError(_) -> #(
          pig_otel.Failed("transport_error"),
          trace_metadata.empty(),
          0,
        )
        transport.Response(status, _, body) -> #(
          http_outcome(status),
          trace_metadata.buffered(
            state.api,
            result.unwrap(bit_array.to_string(body), ""),
          ),
          status,
        )
      }
      annotate_status(state.attempt, status)
      #(end_attempt(State(..state, metadata:), outcome), Ack)
    }
    AbortAttempt -> {
      let next = case state.upstream, state.handle {
        None, Some(handle) -> {
          transport.cancel(handle)
          State(..state, abort: Some(pig_otel.Failed("transport_error")))
        }
        None, None -> end_attempt(state, pig_otel.Failed("transport_error"))
        Some(_), _ -> state
      }
      #(next, Ack)
    }
    SelectStream(target, provider, status) -> {
      annotate_status(state.server, status)
      annotate_status(state.attempt, status)
      case state.logical {
        Some(span) ->
          pig_otel.annotate(span, [
            pig_otel.string_attribute("pig.proxy.target", target),
            pig_otel.string_attribute("pig.proxy.provider", provider),
            pig_otel.bool_attribute("pig.proxy.committed", True),
          ])
        None -> Nil
      }
      #(maybe_end_logical(State(..state, committed: True)), Ack)
    }
    LogicalTerminal(outcome, metadata, status) -> {
      annotate_status(state.server, status)
      let next =
        end_logical(State(..state, metadata:), model_outcome(metadata, outcome))
      #(next, Ack)
    }
    Bind(sink) ->
      case state.handoff {
        AwaitingChunk -> #(State(..state, handoff: Bound(sink)), Ack)
        _ -> #(state, Ack)
      }
    Accepted ->
      case state.handoff {
        Bound(sink) -> {
          process.send(sink, Receipt)
          #(State(..state, handoff: SetupAccepted(sink)), Ack)
        }
        _ -> #(state, Ack)
      }
    HandoffReceipt ->
      case state.handoff, state.handle {
        SetupAccepted(sink), Some(handle) -> {
          transport.start(handle, sink_subject(state.count))
          #(State(..state, handoff: HandedOff(sink)), Ack)
        }
        _, _ -> #(state, Ack)
      }
    Downstream(outcome) -> #(cleanup(state, outcome), Ack)
    Shutdown -> #(cleanup(state, pig_otel.Cancelled("agent_stopped")), Ack)
    Snapshot -> #(
      state,
      Inspect(View(
        state.server != None,
        state.logical != None,
        state.attempt != None,
        is_accepted(state.handoff),
        is_handed_off(state.handoff),
        state.count,
        state.metadata,
      )),
    )
  }
}

fn chunk_sink(handoff: Handoff) -> Option(process.Subject(ChunkMessage)) {
  case handoff {
    AwaitingChunk -> None
    Bound(sink) | SetupAccepted(sink) | HandedOff(sink) -> Some(sink)
  }
}

fn is_accepted(handoff: Handoff) -> Bool {
  case handoff {
    SetupAccepted(_) | HandedOff(_) -> True
    _ -> False
  }
}

fn is_handed_off(handoff: Handoff) -> Bool {
  case handoff {
    HandedOff(_) -> True
    _ -> False
  }
}

/// The request's setup call waits for receipt without blocking the owner loop.
pub fn awaiting_receipt(state: State) -> Bool {
  case state.handoff {
    SetupAccepted(_) -> True
    _ -> False
  }
}

/// Receipt authority for the OTP adapter; never infer it from a call arriving.
pub fn handoff_complete(state: State) -> Bool {
  is_handed_off(state.handoff)
}

fn annotate_status(span: Option(pig_otel.Span), status: Int) -> Nil {
  case span {
    Some(span) if status > 0 ->
      pig_otel.annotate(span, [
        pig_otel.int_attribute("http.response.status_code", status),
      ])
    _ -> Nil
  }
}

/// Deliberate: forwardable HTTP 4xx remains a failed GenAI operation.
pub fn http_outcome(status: Int) -> pig_otel.Outcome {
  case status >= 200 && status < 400 {
    True -> pig_otel.Succeeded
    False -> pig_otel.Failed("http_error")
  }
}

fn model_outcome(
  metadata: trace_metadata.Observed,
  outcome: pig_otel.Outcome,
) -> pig_otel.Outcome {
  case metadata.failed, outcome {
    True, pig_otel.Succeeded -> pig_otel.Failed("provider_error")
    _, _ -> outcome
  }
}

fn end_attempt(state: State, outcome: pig_otel.Outcome) -> State {
  case state.attempt {
    Some(span) -> pig_otel.finish(span, outcome)
    None -> Nil
  }
  State(..state, attempt: None, upstream: Some(outcome))
}

fn end_logical(state: State, outcome: pig_otel.Outcome) -> State {
  case state.logical {
    Some(span) -> {
      pig_otel.annotate(
        span,
        pig_otel.response_attributes(state.metadata.metadata),
      )
      pig_otel.finish(span, outcome)
    }
    None -> Nil
  }
  State(..state, logical: None, logical_closed: True)
}

fn maybe_end_logical(state: State) -> State {
  case state.committed || state.downstream != None, state.upstream {
    True, Some(outcome) ->
      end_logical(
        state,
        model_outcome(state.metadata, option.unwrap(state.downstream, outcome)),
      )
    _, _ -> state
  }
}

/// Ordered source observation finishes the physical attempt at upstream
/// terminal, then includes trailing metadata before logical completion.
pub fn source(
  state: State,
  generation: Int,
  event: transport.SourceEvent,
) -> State {
  case generation != state.count || state.upstream != None {
    True -> state
    False ->
      case event {
        transport.SourceChunk(data) -> {
          let #(framer, metadata) =
            trace_metadata.push(state.api, state.framer, state.metadata, data)
          case state.first_chunk, state.attempt {
            False, Some(span) -> {
              pig_otel.annotate(span, [
                pig_otel.int_attribute(
                  "pig.proxy.upstream_first_chunk_ms",
                  now_ms() - state.attempt_start_time,
                ),
              ])
              annotate_commit(state, False)
            }
            _, _ -> Nil
          }
          State(..state, framer:, metadata:, first_chunk: True)
        }
        transport.SourceDone -> {
          case state.first_chunk {
            False -> annotate_commit(state, True)
            True -> Nil
          }
          upstream_terminal(state, http_outcome(state.attempt_status))
        }
        transport.SourceError(_) ->
          upstream_terminal(
            state,
            option.unwrap(state.abort, pig_otel.Failed("transport_error")),
          )
        transport.SourceHead(status, _) -> {
          annotate_status(state.attempt, status)
          State(..state, attempt_status: status)
        }
        transport.SourceReady(_) -> state
      }
  }
}

fn annotate_commit(state: State, empty: Bool) -> Nil {
  case state.logical {
    Some(span) if state.attempt_status >= 200 && state.attempt_status < 300 ->
      pig_otel.annotate(span, [
        pig_otel.int_attribute(
          "pig.proxy.upstream_commit_ms",
          now_ms() - state.inference_start_time,
        ),
        pig_otel.bool_attribute("pig.proxy.empty_body_commit", empty),
      ])
    _ -> Nil
  }
}

/// A failed metadata/source observer must not strand spans or a downstream
/// loop waiting for a watcher terminal that can never arrive.
pub fn observer_exited(state: State, generation: Int) -> State {
  case generation == state.count && state.upstream == None {
    True -> {
      case state.handle {
        Some(handle) -> transport.cancel(handle)
        None -> Nil
      }
      source(state, generation, transport.SourceError("source observer exited"))
    }
    False -> state
  }
}

fn upstream_terminal(state: State, outcome: pig_otel.Outcome) -> State {
  let next = end_attempt(state, outcome)
  let metadata = trace_metadata.finish(next.api, next.framer, next.metadata)
  let next =
    maybe_end_logical(
      State(..next, metadata:, framer: trace_metadata.new_framer()),
    )
  case next.pending_terminal {
    Some(event) -> upstream(State(..next, pending_terminal: None), event)
    None -> next
  }
}

/// The owner acts as the actual upstream sink. Forwarding cannot precede
/// accepted Mist setup and the chunk process's acknowledged receipt.
/// Old attempt head/body signals cannot commit or finish a newer attempt.
pub fn generation_event(
  state: State,
  generation: Int,
  event: transport.Event,
) -> State {
  case generation == state.count {
    True -> upstream(state, event)
    False -> state
  }
}

pub fn upstream(state: State, event: transport.Event) -> State {
  case state.downstream {
    Some(_) -> state
    None -> forward_upstream(state, event)
  }
}

fn forward_upstream(state: State, event: transport.Event) -> State {
  case event, state.upstream, is_handed_off(state.handoff) {
    transport.Done, None, True
    | transport.StreamError(_), None, True
    | transport.Cancelled, None, True
    -> State(..state, pending_terminal: Some(event))
    _, _, _ -> {
      case is_handed_off(state.handoff), state.head {
        False, Some(head) -> process.send(head, event)
        _, _ -> Nil
      }
      case is_handed_off(state.handoff), chunk_sink(state.handoff) {
        True, Some(sink) -> process.send(sink, Body(event))
        _, _ -> Nil
      }
      state
    }
  }
}

/// The downstream application successfully sent its first chunk.
pub fn application_sent(state: State) -> State {
  case state.first_send, state.server {
    False, Some(span) ->
      pig_otel.annotate(span, [
        pig_otel.int_attribute(
          "pig.proxy.downstream_first_send_ms",
          now_ms() - state.start_time,
        ),
      ])
    _, _ -> Nil
  }
  State(..state, first_send: True)
}

/// Death, cancellation, shutdown and downstream terminal share this arbiter.
/// Already-ended upstream spans are not mutated by late downstream failures.
pub fn cleanup(state: State, outcome: pig_otel.Outcome) -> State {
  case state.downstream {
    Some(_) -> state
    None -> retire_downstream(state, outcome)
  }
}

fn retire_downstream(state: State, outcome: pig_otel.Outcome) -> State {
  case outcome, state.handle {
    pig_otel.Succeeded, _ -> Nil
    _, Some(handle) -> transport.cancel(handle)
    _, None -> Nil
  }
  case outcome, chunk_sink(state.handoff) {
    pig_otel.Succeeded, _ -> Nil
    _, Some(sink) -> process.send(sink, Body(transport.Cancelled))
    _, None -> Nil
  }
  case state.server {
    Some(span) -> pig_otel.finish(span, outcome)
    None -> Nil
  }
  let next = State(..state, server: None, downstream: Some(outcome))
  case next.handle, next.upstream, next.attempt {
    // Streaming cancellation retains upstream spans until its watched
    // terminal. Queued/late usage is decoded before logical completion.
    Some(_), None, Some(_) ->
      State(..next, abort: Some(option.unwrap(state.abort, outcome)))
    _, _, _ -> {
      let next = case next.upstream {
        None -> end_attempt(next, outcome)
        Some(_) -> next
      }
      end_logical(next, outcome)
    }
  }
}

/// An attempt-abort acknowledgement waits for the watched upstream terminal.
pub fn attempt_finished(state: State) -> Bool {
  state.attempt == None
}

/// True only after all three independent boundaries have finalized.
pub fn finished(state: State) -> Bool {
  state.server == None && state.logical == None && state.attempt == None
}

/// A bounded shutdown deadline is a cancellation terminal, never success or
/// proof of physical connection drain. It preserves already observed metadata.
pub fn cancellation_deadline(state: State) -> State {
  let outcome =
    option.unwrap(state.abort, pig_otel.Cancelled("deadline_exceeded"))
  let next = case state.upstream {
    None -> upstream_terminal(state, outcome)
    Some(_) -> state
  }
  end_logical(next, outcome)
}
