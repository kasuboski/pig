//// Feature check boundary for metadata, owned traces and OTP handoffs.

import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleeunit/should
import otel/context
import pig_otel
import pig_proxy/circuit_actor
import pig_proxy/config
import pig_proxy/execution
import pig_proxy/metric_labels
import pig_proxy/model_catalog
import pig_proxy/telemetry
import pig_proxy/trace_metadata
import pig_proxy/tracing
import pig_transport as transport
import simplifile
import support/in_memory_transport

pub type Calls

pub type Call {
  Started(pig_otel.Span, context.Context, pig_otel.Operation)
  Finished(pig_otel.Span, pig_otel.Outcome)
}

@external(erlang, "pig_proxy_trace_test_ffi", "with_calls")
pub fn with_calls(work: fn(Calls) -> a) -> a

@external(erlang, "pig_proxy_trace_test_ffi", "calls")
pub fn calls(recorder: Calls) -> List(Call)

@external(erlang, "pig_proxy_trace_test_ffi", "await_finishes")
pub fn await_finishes(recorder: Calls, count: Int) -> Nil

@external(erlang, "pig_proxy_trace_test_ffi", "wait_closed")
pub fn wait_closed(owner: tracing.Owner, action: fn() -> Nil) -> Nil

@external(erlang, "pig_proxy_trace_test_ffi", "with_composite")
fn with_composite(work: fn() -> a) -> a

pub fn owners() -> tracing.Owners {
  supervised_owners().0
}

pub fn supervised_owners() -> #(tracing.Owners, process.Pid) {
  let name = process.new_name("tracing_check")
  let assert Ok(started) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(tracing.supervisor(name))
    |> static_supervisor.start
  #(name, started.pid)
}

pub fn owner(
  name: tracing.Owners,
  api: pig_otel.Api,
  policy: pig_otel.Policy,
) -> tracing.Owner {
  let route = case api {
    pig_otel.Responses -> "/v1/responses"
    _ -> "/v1/chat/completions"
  }
  let owner = tracing.register(name, policy, [], route)
  let _ =
    tracing.call(owner, tracing.BeginInference(api, None, "fixture_model"))
  owner
}

pub fn view(owner: tracing.Owner) -> tracing.View {
  let assert tracing.Inspect(snapshot) = tracing.call(owner, tracing.Snapshot)
  snapshot
}

pub fn request(api: pig_otel.Api) -> execution.ProxyRequest {
  execution.ProxyRequest(
    "POST",
    case api {
      pig_otel.Responses -> "/v1/responses"
      _ -> "/v1/chat/completions"
    },
    [],
    "{}",
    "fixture_model",
  )
}

pub fn executor(
  adapter: transport.Transport,
  owner: tracing.Owner,
) -> execution.Executor {
  let base =
    execution.executor(adapter, None)
    |> execution.with_tracing(owner)
  execution.Executor(..base, sleep: fn(_) { Nil }, upstream_timeout_ms: 1000)
}

pub fn chain() -> execution.FallbackChain {
  execution.FallbackChain([
    config.openai_target("primary", "http://fixture/v1", "PRIVATE_CREDENTIAL"),
  ])
}

pub fn check_buffered(
  api: pig_otel.Api,
  body: String,
  expected: trace_metadata.Observed,
) -> Nil {
  should.equal(trace_metadata.buffered(api, body), expected)
}

pub fn check_incremental(
  api: pig_otel.Api,
  chunks: List(String),
  expected: trace_metadata.Observed,
) -> Nil {
  let #(framer, observed) =
    list.fold(
      chunks,
      #(trace_metadata.new_framer(), trace_metadata.empty()),
      fn(state, chunk) {
        trace_metadata.push(api, state.0, state.1, bit_array.from_string(chunk))
      },
    )
  should.equal(trace_metadata.finish(api, framer, observed), expected)
}

pub fn check_labels() -> Nil {
  metric_labels.configure(
    metric_labels.Identities(
      model_catalog.empty,
      ["fixture_model"],
      ["primary"],
      ["openai"],
    ),
  )
  let events =
    list.map(["fixture_model", "PRIVATE_MODEL_A", "PRIVATE_MODEL_B"], fn(model) {
      telemetry.normalize(telemetry.RequestStop(
        "PRIVATE_TARGET",
        "PRIVATE_PROVIDER",
        model,
        200,
        1,
        None,
        None,
        None,
      ))
    })
  let expected =
    list.map(["fixture_model", "unknown", "unknown"], fn(model) {
      telemetry.RequestStop(
        "unknown",
        "unknown",
        model,
        200,
        1,
        None,
        None,
        None,
      )
    })
  should.equal(events, expected)
  metric_labels.configure(
    metric_labels.Identities(model_catalog.empty, [], [], [""]),
  )
}

pub fn check_sync(
  api: pig_otel.Api,
  responses: List(transport.Response),
  final_status: Int,
  attempts: Int,
) -> Nil {
  use recorder <- with_calls
  use <- with_composite
  let owner = owner(owners(), api, pig_otel.MetadataOnly)
  let assert Ok(script) =
    in_memory_transport.start(responses, transport.TransportError("exhausted"))
  let outcome =
    execution.orchestrate(
      executor(in_memory_transport.transport(script), owner),
      request(api),
      chain(),
    )
  let assert execution.Committed(status:, body:, ..) = outcome
  should.equal(status, final_status)
  let observed =
    trace_metadata.buffered(api, case bit_array.to_string(body) {
      Ok(body) -> body
      Error(_) -> ""
    })
  let _ =
    tracing.call(
      owner,
      tracing.LogicalTerminal(tracing.http_outcome(status), observed, status),
    )
  let live = view(owner)
  should.equal(#(live.server_live, live.logical_live, live.attempt_live), #(
    True,
    False,
    False,
  ))
  wait_closed(owner, fn() {
    let _ =
      tracing.call(owner, tracing.Downstream(tracing.http_outcome(status)))
    Nil
  })
  let events = calls(recorder)
  let started =
    list.filter_map(events, fn(event) {
      case event {
        Started(_, _, op) -> Ok(op)
        _ -> Error(Nil)
      }
    })
  let finished =
    list.filter_map(events, fn(event) {
      case event {
        Finished(_, outcome) -> Ok(outcome)
        _ -> Error(Nil)
      }
    })
  should.equal(list.length(started), attempts + 2)
  should.equal(list.length(finished), attempts + 2)
  should.equal(
    list.length(
      list.filter(started, fn(op) {
        case op {
          pig_otel.HttpAttempt(_) -> True
          _ -> False
        }
      }),
    ),
    attempts,
  )
  let logical = case observed.failed, tracing.http_outcome(status) {
    True, pig_otel.Succeeded -> pig_otel.Failed("provider_error")
    _, outcome -> outcome
  }
  should.equal(list.drop(finished, attempts), [
    logical,
    tracing.http_outcome(status),
  ])
}

/// The real source is paused after commit so handoff/death is acknowledged,
/// not arranged with timing sleeps.
pub type SourceCommand {
  Complete
  Fail
  Crash
  Duplicate
}

pub type SourceReady {
  SourceReady(control: process.Subject(SourceCommand), context: context.Context)
}

pub fn source_adapter(
  ready: process.Subject(SourceReady),
  api: pig_otel.Api,
) -> transport.Transport {
  transport.Transport(
    sync: fn(_) { transport.TransportError("not buffered") },
    stream: fn(_, sink) {
      let control = process.new_subject()
      process.send(ready, SourceReady(control, context.current()))
      process.send(sink, transport.SourceHead(200, []))
      process.send(
        sink,
        transport.SourceChunk(bit_array.from_string("data: {}\n\n")),
      )
      case process.receive_forever(control) {
        Complete | Duplicate -> {
          let usage = case api {
            pig_otel.Responses ->
              "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"model\":\"m\",\"status\":\"completed\",\"usage\":{\"input_tokens\":9,\"output_tokens\":3}}}\n\n"
            _ ->
              "data: {\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":3}}\n\n"
          }
          process.send(
            sink,
            transport.SourceChunk(bit_array.from_string(usage)),
          )
          process.send(sink, transport.SourceDone)
          process.send(sink, transport.SourceDone)
          process.send(sink, transport.SourceError("PRIVATE_LATE_ERROR"))
        }
        Fail ->
          process.send(sink, transport.SourceError("PRIVATE_SOURCE_ERROR"))
        Crash -> panic as "PRIVATE_CALLBACK_EXCEPTION"
      }
    },
  )
}

pub fn check_stream(api: pig_otel.Api, terminal: SourceCommand) -> Nil {
  use recorder <- with_calls
  let owner = owner(owners(), api, pig_otel.MetadataOnly)
  let ready = process.new_subject()
  let outcome =
    execution.orchestrate_stream(
      executor(source_adapter(ready, api), owner),
      request(api),
      chain(),
    )
  let assert execution.CommittedStream(target_id:, provider:, status:, ..) =
    outcome
  let _ = tracing.call(owner, tracing.SelectStream(target_id, provider, status))
  let before = view(owner)
  should.equal(
    #(before.server_live, before.logical_live, before.attempt_live),
    #(True, True, True),
  )
  let SourceReady(control, callback_context) = process.receive_forever(ready)
  let events = calls(recorder)
  let assert Ok(Started(attempt_span, _, pig_otel.HttpAttempt(_))) =
    list.find_map(events, fn(event) {
      case event {
        Started(_, _, pig_otel.HttpAttempt(_)) -> Ok(event)
        _ -> Error(Nil)
      }
    })
  should.equal(callback_context, pig_otel.context(attempt_span))
  let sink = process.new_subject()
  let _ = tracing.call(owner, tracing.Bind(sink))
  let bound = view(owner)
  should.equal(#(bound.accepted, bound.handed_off), #(False, False))
  let _ = tracing.call(owner, tracing.HandoffReceipt)
  should.equal(view(owner).handed_off, False)
  accept(owner, sink)
  should.equal(view(owner).handed_off, True)
  process.send(control, terminal)
  drain_stream(sink, terminal)
  let after = view(owner)
  should.equal(#(after.server_live, after.logical_live, after.attempt_live), #(
    True,
    False,
    False,
  ))
  case terminal {
    Complete | Duplicate ->
      should.equal(after.metadata.metadata.input_tokens, Some(9))
    _ -> should.equal(after.metadata.metadata.input_tokens, None)
  }
  let outcome = case terminal {
    Complete | Duplicate -> pig_otel.Succeeded
    _ -> pig_otel.Failed("transport_error")
  }
  wait_closed(owner, fn() {
    let _ = tracing.call(owner, tracing.Downstream(outcome))
    Nil
  })
  let ended =
    list.filter(calls(recorder), fn(event) {
      case event {
        Finished(_, _) -> True
        _ -> False
      }
    })
  should.equal(list.length(ended), 3)
  let _ =
    tracing.call(owner, tracing.Downstream(pig_otel.Failed("downstream_error")))
  should.equal(
    list.length(
      list.filter(calls(recorder), fn(event) {
        case event {
          Finished(_, _) -> True
          _ -> False
        }
      }),
    ),
    3,
  )
}

fn drain_stream(
  sink: process.Subject(tracing.ChunkMessage),
  terminal: SourceCommand,
) -> Nil {
  case process.receive_forever(sink) {
    tracing.Body(transport.Chunk(_)) -> drain_stream(sink, terminal)
    tracing.Body(transport.Done) ->
      should.be_true(terminal == Complete || terminal == Duplicate)
    tracing.Body(transport.StreamError(_)) ->
      should.be_true(terminal == Fail || terminal == Crash)
    _ -> panic as "unexpected chunk-loop message"
  }
}

pub fn check_fixture(
  api: pig_otel.Api,
  path: String,
  streaming: Bool,
  expected: trace_metadata.Observed,
) -> Nil {
  let assert Ok(body) = simplifile.read("test_data/tracing/" <> path)
  case streaming {
    False -> check_buffered(api, body, expected)
    True -> {
      // Exercise byte-sized input, including boundaries inside UTF-8 and SSE
      // delimiters, without coupling fixtures to transport chunk sizes.
      let bits = bit_array.from_string(body)
      let #(framer, observed) =
        feed_bytes(
          bits,
          api,
          trace_metadata.new_framer(),
          trace_metadata.empty(),
        )
      should.equal(trace_metadata.finish(api, framer, observed), expected)
    }
  }
}

fn feed_bytes(
  bits: BitArray,
  api: pig_otel.Api,
  framer: trace_metadata.Framer,
  observed: trace_metadata.Observed,
) -> #(trace_metadata.Framer, trace_metadata.Observed) {
  case bits {
    <<byte, rest:bits>> -> {
      let #(framer, observed) =
        trace_metadata.push(api, framer, observed, <<byte>>)
      feed_bytes(rest, api, framer, observed)
    }
    <<>> -> #(framer, observed)
    _ -> panic as "fixture is not byte-aligned"
  }
}

/// Per-send attempt evidence covers fallback, circuit skip and successful
/// empty-body streaming commitment, including terminals before chunk init.
pub fn check_attempts(
  api: pig_otel.Api,
  streaming: Bool,
  skipped: Bool,
) -> Nil {
  use recorder <- with_calls
  let owner = owner(owners(), api, pig_otel.MetadataOnly)
  let assert Ok(circuit) = circuit_actor.start(1, 60_000)
  case skipped {
    True -> circuit_actor.record_failure(circuit, "primary")
    False -> Nil
  }
  let sync = case skipped {
    True -> [transport.Response(200, [], <<>>)]
    False -> [
      transport.Response(500, [], <<>>),
      transport.Response(500, [], <<>>),
      transport.Response(200, [], <<>>),
    ]
  }
  let stream = case skipped {
    True -> [
      in_memory_transport.CommitStream(
        200,
        [],
        [],
        in_memory_transport.StreamDone,
      ),
    ]
    False -> [
      in_memory_transport.FailStream("PRIVATE_ERROR"),
      in_memory_transport.FailStream("PRIVATE_ERROR"),
      in_memory_transport.CommitStream(
        200,
        [],
        [],
        in_memory_transport.StreamDone,
      ),
    ]
  }
  let assert Ok(script) =
    in_memory_transport.start_with(
      sync,
      transport.TransportError("exhausted"),
      stream,
      in_memory_transport.stream_exhausted_default,
    )
  let base = executor(in_memory_transport.transport(script), owner)
  let exec = execution.Executor(..base, circuit: Some(circuit))
  let chain =
    execution.FallbackChain([
      config.openai_target("primary", "http://fixture/v1", "key"),
      config.openai_target("backup", "http://other/v1", "key"),
    ])
  let attempts = case skipped {
    True -> 1
    False -> 3
  }
  case streaming {
    False -> {
      let assert execution.Committed(status: 200, ..) =
        execution.orchestrate(exec, request(api), chain)
      let _ =
        tracing.call(
          owner,
          tracing.LogicalTerminal(
            pig_otel.Succeeded,
            trace_metadata.empty(),
            200,
          ),
        )
      Nil
    }
    True -> {
      let assert execution.CommittedStream(target_id:, provider:, status:, ..) =
        execution.orchestrate_stream(exec, request(api), chain)
      let _ =
        tracing.call(owner, tracing.SelectStream(target_id, provider, status))
      await_finishes(recorder, attempts + 1)
      let before_init = view(owner)
      should.equal(
        #(
          before_init.server_live,
          before_init.logical_live,
          before_init.attempt_live,
        ),
        #(True, False, False),
      )
      should.equal(before_init.metadata.metadata.input_tokens, None)
      let sink = process.new_subject()
      let _ = tracing.call(owner, tracing.Bind(sink))
      accept(owner, sink)
      should.equal(process.receive_forever(sink), tracing.Body(transport.Done))
    }
  }
  wait_closed(owner, fn() {
    let _ = tracing.call(owner, tracing.Downstream(pig_otel.Succeeded))
    Nil
  })
  let events = calls(recorder)
  let physical =
    list.filter_map(events, fn(event) {
      case event {
        Started(_, _, pig_otel.HttpAttempt(target)) -> Ok(target)
        _ -> Error(Nil)
      }
    })
  should.equal(physical, case skipped {
    True -> ["backup"]
    False -> ["primary", "primary", "backup"]
  })
  let terminals =
    list.filter_map(events, fn(event) {
      case event {
        Finished(_, terminal) -> Ok(terminal)
        _ -> Error(Nil)
      }
    })
  should.equal(list.length(terminals), attempts + 2)
  should.equal(list.drop(terminals, attempts), [
    pig_otel.Succeeded,
    pig_otel.Succeeded,
  ])
}

fn accept(
  owner: tracing.Owner,
  sink: process.Subject(tracing.ChunkMessage),
) -> Nil {
  let setup_ack = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let reply = tracing.call(owner, tracing.Accepted)
      process.send(setup_ack, reply)
    })
  should.equal(process.receive_forever(sink), tracing.Receipt)
  let _ = tracing.call(owner, tracing.HandoffReceipt)
  should.equal(process.receive_forever(setup_ack), tracing.Ack)
}
