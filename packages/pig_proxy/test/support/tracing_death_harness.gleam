//// Real OTP death boundaries, driven by acknowledgements rather than sleeps.

import gleam/erlang/process
import gleam/list
import gleam/otp/factory_supervisor as factory
import gleeunit/should
import otel/context
import pig_otel
import pig_otel/identity
import pig_proxy/execution
import pig_proxy/tracing
import pig_transport as transport
import support/tracing_harness as check

pub type Boundary {
  BeforeInit
  DuringHandoff
  UpstreamFinishedBeforeHandoff
  AfterAcknowledgement
  ChunkException
  SendFailure
  Cancellation
  Shutdown
  SupervisorShutdown
}

type RequestCommand {
  Accept
  Retire
}

type ChunkCommand {
  Crash
  RetireChunk
}

type ChunkInput {
  Message(tracing.ChunkMessage)
  Control(ChunkCommand)
}

type Event {
  RequestReady(tracing.Owner, process.Subject(RequestCommand))
  ChunkReady(process.Subject(ChunkCommand))
  Accepted
  ReceiptAcknowledged
}

@external(erlang, "pig_proxy_trace_death_test_ffi", "wait_retired")
fn wait_retired(subject: process.Subject(a), action: fn() -> Nil) -> Nil

@external(erlang, "pig_proxy_trace_death_test_ffi", "shutdown_supervisor")
fn shutdown_supervisor(pid: process.Pid) -> Nil

pub fn check_death(api: pig_otel.Api, boundary: Boundary) -> Nil {
  use recorder <- check.with_calls
  let #(owners, supervisor) = check.supervised_owners()
  let events = process.new_subject()
  let source = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      let owner = check.owner(owners, api, pig_otel.MetadataOnly)
      let outcome =
        execution.orchestrate_stream(
          check.executor(check.source_adapter(source, api), owner),
          check.request(api),
          check.chain(),
        )
      let assert execution.CommittedStream(target_id:, provider:, status:, ..) =
        outcome
      let _ =
        tracing.call(owner, tracing.SelectStream(target_id, provider, status))
      process.send(events, RequestReady(owner, control))
      request_loop(owner, control, events)
    })
  let assert RequestReady(owner, request_control) =
    process.receive_forever(events)
  let check.SourceReady(source_control, _) = process.receive_forever(source)
  case boundary {
    UpstreamFinishedBeforeHandoff -> {
      process.send(source_control, check.Complete)
      check.await_finishes(recorder, 2)
      let upstream_done = check.view(owner)
      should.equal(
        #(
          upstream_done.server_live,
          upstream_done.logical_live,
          upstream_done.attempt_live,
        ),
        #(True, False, False),
      )
    }
    _ -> Nil
  }
  case boundary {
    BeforeInit ->
      check.wait_closed(owner, fn() { process.send(request_control, Retire) })
    _ -> {
      let _ =
        process.spawn_unlinked(fn() {
          let control = process.new_subject()
          let sink = process.new_subject()
          let _ = tracing.call(owner, tracing.Bind(sink))
          process.send(events, ChunkReady(control))
          chunk_loop(owner, sink, control, events)
        })
      let assert ChunkReady(chunk_control) = process.receive_forever(events)
      case boundary {
        DuringHandoff | UpstreamFinishedBeforeHandoff -> {
          check.wait_closed(owner, fn() {
            process.send(request_control, Retire)
          })
          wait_retired(chunk_control, fn() { Nil })
        }
        _ -> {
          process.send(request_control, Accept)
          let first = process.receive_forever(events)
          let second = process.receive_forever(events)
          should.be_true(first == Accepted || first == ReceiptAcknowledged)
          should.be_true(second == Accepted || second == ReceiptAcknowledged)
          should.not_equal(first, second)
          wait_retired(request_control, fn() {
            process.send(request_control, Retire)
          })
          // A normally retired request cannot cancel an acknowledged stream.
          let live = check.view(owner)
          should.equal(
            #(
              live.server_live,
              live.logical_live,
              live.attempt_live,
              live.handed_off,
            ),
            #(True, True, True, True),
          )
          check.wait_closed(owner, fn() {
            case boundary {
              AfterAcknowledgement -> process.send(chunk_control, RetireChunk)
              ChunkException -> process.send(chunk_control, Crash)
              SendFailure -> {
                let _ =
                  tracing.call(
                    owner,
                    tracing.Downstream(pig_otel.Failed("downstream_error")),
                  )
                Nil
              }
              Cancellation -> {
                let _ =
                  tracing.call(
                    owner,
                    tracing.Downstream(pig_otel.Cancelled("cancelled")),
                  )
                Nil
              }
              Shutdown -> {
                let _ = tracing.call(owner, tracing.Shutdown)
                Nil
              }
              SupervisorShutdown -> shutdown_supervisor(supervisor)
              _ -> panic as "invalid check boundary"
            }
          })
        }
      }
    }
  }
  let events = check.calls(recorder)
  let starts =
    list.filter(events, fn(event) {
      case event {
        check.Started(_, _, _) -> True
        _ -> False
      }
    })
  let finishes =
    list.filter(events, fn(event) {
      case event {
        check.Finished(_, _) -> True
        _ -> False
      }
    })
  should.equal(list.length(starts), 3)
  should.equal(list.length(finishes), 3)
}

fn request_loop(
  owner: tracing.Owner,
  control: process.Subject(RequestCommand),
  events: process.Subject(Event),
) -> Nil {
  case process.receive_forever(control) {
    Retire -> Nil
    Accept -> {
      let _ = tracing.call(owner, tracing.Accepted)
      process.send(events, Accepted)
      request_loop(owner, control, events)
    }
  }
}

fn chunk_loop(
  owner: tracing.Owner,
  sink: process.Subject(tracing.ChunkMessage),
  control: process.Subject(ChunkCommand),
  events: process.Subject(Event),
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(sink, Message)
    |> process.select_map(control, Control)
  case process.selector_receive_forever(selector) {
    Message(tracing.Receipt) -> {
      let _ = tracing.call(owner, tracing.HandoffReceipt)
      process.send(events, ReceiptAcknowledged)
      chunk_loop(owner, sink, control, events)
    }
    Message(tracing.Body(transport.Chunk(_))) ->
      chunk_loop(owner, sink, control, events)
    Message(_) -> Nil
    Control(RetireChunk) -> Nil
    Control(Crash) -> panic as "PRIVATE_CHUNK_CALLBACK_ERROR"
  }
}

pub fn check_dormant_registration() -> Nil {
  use recorder <- check.with_calls
  let owners = check.owners()
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      let boot =
        tracing.Registration(
          process.self(),
          pig_otel.MetadataOnly,
          context.current(),
          identity.empty(),
          "/v1/responses",
        )
      let assert Ok(started) =
        factory.start_child(factory.get_by_name(owners), boot)
      process.send(ready, #(started.data, control))
      let _ = process.receive_forever(control)
      Nil
    })
  let #(owner, control) = process.receive_forever(ready)
  let dormant = check.view(owner)
  should.equal(
    #(dormant.server_live, dormant.logical_live, dormant.attempt_live),
    #(False, False, False),
  )
  check.wait_closed(owner, fn() { process.send(control, Nil) })
  should.equal(check.calls(recorder), [])
}
