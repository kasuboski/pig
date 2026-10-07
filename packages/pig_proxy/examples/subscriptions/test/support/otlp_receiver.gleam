//// Real loopback OTLP transport with a synchronous, typed span collector.

import exception
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import mist
import support/otlp_decode
import support/otlp_verify

/// A receiver and its owned listener and collector processes.
pub opaque type Receiver {
  Receiver(
    collector: process.Subject(Message),
    collector_pid: process.Pid,
    listener_pid: process.Pid,
    port: Int,
  )
}

type WireFailure {
  InvalidHeaders
  InvalidBody
  InvalidProtobuf
}

type Message {
  Record(Result(List(otlp_verify.Span), WireFailure), process.Subject(Nil))
  Inspect(process.Subject(Result(List(otlp_verify.Span), WireFailure)))
  Await(
    process.Subject(#(Result(List(otlp_verify.Span), WireFailure), List(Int))),
  )
  Stop
}

type State {
  State(
    spans: List(otlp_verify.Span),
    batch_sizes: List(Int),
    failure: Option(WireFailure),
    waiters: List(
      process.Subject(#(Result(List(otlp_verify.Span), WireFailure), List(Int))),
    ),
  )
}

/// Start a receiver on an assigned loopback port.
pub fn start() -> Receiver {
  let assert Ok(collector) =
    actor.new(State([], [], None, []))
    |> actor.on_message(handle_message)
    |> actor.start
  let port_subject = process.new_subject()
  let handler = fn(req) { receive_export(req, collector.data) }
  let started =
    handler
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(port_subject, port) })
    |> mist.start
  case started {
    Error(_) -> {
      stop_process(collector.pid)
      panic as "failed to start loopback OTLP receiver"
    }
    Ok(listener) -> {
      let assert Ok(port) = process.receive(port_subject, 5000)
      Receiver(collector.data, collector.pid, listener.pid, port)
    }
  }
}

/// Return the exact signal-specific traces URL.
pub fn endpoint(receiver: Receiver) -> String {
  "http://127.0.0.1:" <> int.to_string(receiver.port) <> "/v1/traces"
}

/// Assert the periodic exporter has not masked the shutdown gate.
pub fn assert_no_export(receiver: Receiver) -> Nil {
  let assert Ok([]) = actor.call(receiver.collector, 1000, Inspect)
  Nil
}

/// Await the acknowledged export and verify the complete span contract.
pub fn verify(receiver: Receiver, capture: Bool) -> Nil {
  let #(decoded, batch_sizes) = actor.call(receiver.collector, 15_000, Await)
  let assert Ok(spans) = decoded
  let assert Ok(Nil) = otlp_verify.verify(spans, capture)
  assert list.length(batch_sizes) >= 3
  assert list.all(batch_sizes, fn(size) { size > 0 && size <= 4 })
  assert list.fold(batch_sizes, 0, int.add) == list.length(spans)
  Nil
}

/// Stop both owned processes, including after a failed assertion.
pub fn stop(receiver: Receiver) -> Nil {
  stop_process(receiver.listener_pid)
  let monitor = process.monitor(receiver.collector_pid)
  process.unlink(receiver.collector_pid)
  process.send(receiver.collector, Stop)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
  case process.selector_receive(selector, 1000) {
    Ok(Nil) -> Nil
    Error(_) -> process.kill(receiver.collector_pid)
  }
  process.demonitor_process(monitor)
}

fn receive_export(
  req: request.Request(mist.Connection),
  collector: process.Subject(Message),
) -> response.Response(mist.ResponseData) {
  let headers_ok =
    req.method == http.Post
    && request.get_header(req, "authorization")
    == Ok("Bearer synthetic-latitude-key")
    && request.get_header(req, "x-latitude-project") == Ok("synthetic-project")
    && request.get_header(req, "content-type") == Ok("application/x-protobuf")
    && request.get_header(req, "content-encoding") == Error(Nil)
  let decoded = case headers_ok, mist.read_body(req, 16_777_216) {
    False, _ -> Error(InvalidHeaders)
    True, Error(_) -> Error(InvalidBody)
    True, Ok(read) -> {
      case otlp_decode.decode(read.body, req.path) {
        Ok(spans) -> Ok(spans)
        Error(_) -> Error(InvalidProtobuf)
      }
    }
  }
  // Recording completes before ACK, so snapshots cannot miss an accepted batch.
  actor.call(collector, 1000, fn(reply) { Record(decoded, reply) })
  let status = case decoded {
    Ok(_) -> 200
    Error(_) -> 400
  }
  response.new(status)
  |> response.set_header("content-type", "application/x-protobuf")
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn snapshot(state: State) -> Result(List(otlp_verify.Span), WireFailure) {
  case state.failure {
    Some(failure) -> Error(failure)
    None -> Ok(state.spans)
  }
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Stop -> actor.stop()
    Inspect(reply) -> {
      process.send(reply, snapshot(state))
      actor.continue(state)
    }
    Await(reply) -> {
      case list.length(state.spans) >= 26 || state.failure != None {
        True -> {
          process.send(reply, #(
            snapshot(state),
            list.reverse(state.batch_sizes),
          ))
          actor.continue(state)
        }
        False ->
          actor.continue(State(..state, waiters: [reply, ..state.waiters]))
      }
    }
    Record(decoded, reply) -> {
      let next = case decoded {
        Ok(spans) ->
          State(..state, spans: list.append(state.spans, spans), batch_sizes: [
            list.length(spans),
            ..state.batch_sizes
          ])
        Error(failure) -> State(..state, failure: Some(failure))
      }
      process.send(reply, Nil)
      case list.length(next.spans) >= 26 || next.failure != None {
        True -> {
          list.each(next.waiters, fn(waiter) {
            process.send(waiter, #(
              snapshot(next),
              list.reverse(next.batch_sizes),
            ))
          })
          actor.continue(State(..next, waiters: []))
        }
        False -> actor.continue(next)
      }
    }
  }
}

type ForeignStopResult

@external(erlang, "gen_server", "stop")
fn terminate(
  pid: process.Pid,
  reason: process.ExitReason,
  timeout: Int,
) -> ForeignStopResult

fn stop_process(pid: process.Pid) -> Nil {
  process.unlink(pid)
  case exception.rescue(fn() { terminate(pid, process.Normal, 1000) }) {
    Ok(_) -> Nil
    Error(_) -> {
      case process.is_alive(pid) {
        True -> process.kill(pid)
        False -> Nil
      }
    }
  }
}
