//// Real loopback HTTP providers with synchronized request recording.

import exception
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import mist

/// Exact request data received at the upstream HTTP boundary.
pub type RecordedRequest {
  RecordedRequest(path: String, headers: List(#(String, String)), body: String)
}

type Message {
  Record(RecordedRequest, process.Subject(Nil))
  Count(process.Subject(Int))
  Take(process.Subject(Option(RecordedRequest)))
  Stop
}

type State {
  State(requests: List(RecordedRequest), total: Int)
}

/// The fixture's owned listener and synchronized collector.
pub opaque type Fixture {
  Fixture(
    port: Int,
    listener_pid: process.Pid,
    collector_pid: process.Pid,
    collector: process.Subject(Message),
  )
}

/// Start a provider on an assigned loopback port.
pub fn start() -> Fixture {
  let assert Ok(collector) =
    actor.new(State([], 0))
    |> actor.on_message(handle_message)
    |> actor.start
  let ready = process.new_subject()
  let started =
    fn(req) { handle_request(req, collector.data) }
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
    |> mist.start
  case started {
    Ok(listener) -> {
      let assert Ok(port) = process.receive(ready, 5000)
      Fixture(port, listener.pid, collector.pid, collector.data)
    }
    Error(_) -> {
      stop_process(collector.pid)
      panic as "failed to start loopback upstream"
    }
  }
}

/// Return the assigned port.
pub fn port(fixture: Fixture) -> Int {
  fixture.port
}

/// Count every request, including those already consumed by take.
pub fn count(fixture: Fixture) -> Int {
  actor.call(fixture.collector, 1000, Count)
}

/// Take the oldest request already acknowledged by this fixture.
pub fn take(fixture: Fixture) -> RecordedRequest {
  let assert Some(recorded) = actor.call(fixture.collector, 1000, Take)
  recorded
}

/// Stop all fixture processes, even after a test assertion fails.
pub fn stop(fixture: Fixture) -> Nil {
  stop_process(fixture.listener_pid)
  let monitor = process.monitor(fixture.collector_pid)
  process.unlink(fixture.collector_pid)
  process.send(fixture.collector, Stop)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
  case process.selector_receive(selector, 1000) {
    Ok(Nil) -> Nil
    Error(_) -> process.kill(fixture.collector_pid)
  }
  process.demonitor_process(monitor)
}

fn handle_request(
  req: request.Request(mist.Connection),
  collector: process.Subject(Message),
) -> response.Response(mist.ResponseData) {
  let assert Ok(read) = mist.read_body(req, 1_048_576)
  let assert Ok(body) = bit_array.to_string(read.body)
  actor.call(collector, 1000, fn(reply) {
    Record(RecordedRequest(req.path, req.headers, body), reply)
  })
  let streaming_decoder = {
    use stream <- decode.field("stream", decode.bool)
    decode.success(stream)
  }
  let assert Ok(streaming) = json.parse(body, streaming_decoder)
  let #(content_type, payload) = response_for(req.path, streaming)
  response.new(200)
  |> response.set_header("content-type", content_type)
  |> response.set_body(mist.Bytes(bytes_tree.from_string(payload)))
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Stop -> actor.stop()
    Record(recorded, reply) -> {
      process.send(reply, Nil)
      actor.continue(State(
        list.append(state.requests, [recorded]),
        state.total + 1,
      ))
    }
    Count(reply) -> {
      process.send(reply, state.total)
      actor.continue(state)
    }
    Take(reply) -> {
      case state.requests {
        [recorded, ..rest] -> {
          process.send(reply, Some(recorded))
          actor.continue(State(rest, state.total))
        }
        [] -> {
          process.send(reply, None)
          actor.continue(state)
        }
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

fn array(values: List(json.Json)) -> json.Json {
  json.array(values, fn(value) { value })
}

fn response_for(path: String, streaming: Bool) -> #(String, String) {
  case path == "/codex/responses" {
    True -> {
      let response =
        json.object([
          #("id", json.string("responses-fixture")),
          #("model", json.string("fake-codex")),
          #("status", json.string("completed")),
          #(
            "usage",
            json.object([
              #("input_tokens", json.int(11)),
              #("output_tokens", json.int(7)),
              #(
                "input_tokens_details",
                json.object([#("cached_tokens", json.int(3))]),
              ),
            ]),
          ),
          #(
            "output",
            array([
              json.object([
                #("type", json.string("message")),
                #("role", json.string("assistant")),
                #(
                  "content",
                  array([
                    json.object([
                      #("type", json.string("output_text")),
                      #("text", json.string("responses-output-marker")),
                    ]),
                  ]),
                ),
              ]),
            ]),
          ),
        ])
        |> json.to_string
      case streaming {
        True -> #(
          "text/event-stream",
          "data: {\"type\":\"response.completed\",\"response\":"
            <> response
            <> "}\n\n",
        )
        False -> #("application/json", response)
      }
    }
    False -> {
      let usage =
        json.object([
          #("prompt_tokens", json.int(11)),
          #("completion_tokens", json.int(7)),
          #("total_tokens", json.int(18)),
          #(
            "prompt_tokens_details",
            json.object([#("cached_tokens", json.int(3))]),
          ),
        ])
      let base = [
        #("id", json.string("chat-fixture")),
        #("model", json.string("fake-zai")),
      ]
      let choice =
        json.object([
          #("index", json.int(0)),
          #(
            "message",
            json.object([
              #("role", json.string("assistant")),
              #("content", json.string("chat-output-marker")),
            ]),
          ),
          #("finish_reason", json.string("stop")),
        ])
      let body =
        json.object(
          list.append(base, [
            #("choices", array([choice])),
            #("usage", usage),
          ]),
        )
        |> json.to_string
      case streaming {
        True -> {
          let chunk =
            json.object([
              #("id", json.string("chat-fixture")),
              #("model", json.string("fake-zai")),
              #(
                "choices",
                array([
                  json.object([
                    #("index", json.int(0)),
                    #(
                      "delta",
                      json.object([
                        #("role", json.string("assistant")),
                        #("content", json.string("chat-output-marker")),
                      ]),
                    ),
                    #("finish_reason", json.string("stop")),
                  ]),
                ]),
              ),
            ])
            |> json.to_string
          let final =
            json.object(
              list.append(base, [
                #("choices", array([])),
                #("usage", usage),
              ]),
            )
            |> json.to_string
          #(
            "text/event-stream",
            "data: " <> chunk <> "\n\ndata: " <> final <> "\n\ndata: [DONE]\n\n",
          )
        }
        False -> #("application/json", body)
      }
    }
  }
}
