//// Real OTP runtime shutdown checks. All state assembly stays at this boundary.

import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import pig_otel
import pig_proxy/config
import pig_proxy/execution
import pig_proxy/metric_labels
import pig_proxy/model_catalog
import pig_proxy/runtime
import pig_proxy/server
import pig_proxy/telemetry
import pig_proxy/tracing
import support/tracing_harness as trace

pub type Ownership {
  Managed
  External
}

@external(erlang, "pig_proxy_runtime_test_ffi", "wait_tree_stopped")
fn wait_tree_stopped(root: process.Pid, stop: fn() -> Nil) -> Nil

fn state(owners: tracing.Owners, root: process.Pid) -> server.ServerState {
  server.ServerState(
    supervisor: Some(root),
    config: config.new([]),
    emitter: telemetry.emitter(
      metric_labels.Identities(model_catalog.empty, [], [], []),
      fn(_) { Nil },
    ),
    owners:,
    circuit: process.new_name("unused_circuit"),
    catalog: process.new_name("unused_catalog"),
    metrics: process.new_name("unused_metrics"),
    vault: None,
  )
}

pub fn check_stop(api: pig_otel.Api, ownership: Ownership) -> Nil {
  use recorder <- trace.with_calls
  let #(owners, root) = trace.supervised_owners()
  let state = state(owners, root)
  // register activates only after the factory has acknowledged registration.
  let owner = trace.owner(owners, api, pig_otel.MetadataOnly)
  let source = process.new_subject()
  let outcome =
    execution.orchestrate_stream(
      trace.executor(trace.source_adapter(source, api), owner),
      trace.request(api),
      trace.chain(),
    )
  let assert execution.CommittedStream(target_id:, provider:, status:, ..) =
    outcome
  let _ = tracing.call(owner, tracing.SelectStream(target_id, provider, status))
  let trace.SourceReady(_, _) = process.receive_forever(source)
  let before = trace.view(owner)
  should.equal(
    #(
      before.server_live,
      before.logical_live,
      before.attempt_live,
      before.handed_off,
    ),
    #(True, True, True, False),
  )
  let calls_before = trace.calls(recorder)
  let starts =
    list.filter(calls_before, fn(event) {
      case event {
        trace.Started(_, _, _) -> True
        _ -> False
      }
    })
  let assert [
    trace.Started(server_span, _, pig_otel.HttpServer(_)),
    trace.Started(logical_span, _, pig_otel.Inference(_, _, _)),
    trace.Started(attempt_span, _, pig_otel.HttpAttempt(_)),
  ] = starts
  case ownership {
    External -> {
      runtime.stop(server.ServerState(..state, supervisor: None))
      should.equal(trace.view(owner), before)
      should.equal(
        list.filter(trace.calls(recorder), fn(event) {
          case event {
            trace.Started(_, _, _) -> True
            _ -> False
          }
        }),
        starts,
      )
    }
    Managed -> Nil
  }
  wait_tree_stopped(root, fn() {
    runtime.stop(state)
    // The stop return, not a later owner ACK, is the trace cleanup boundary.
    should.equal(
      list.filter(trace.calls(recorder), fn(event) {
        case event {
          trace.Finished(_, _) -> True
          _ -> False
        }
      }),
      [
        trace.Finished(server_span, pig_otel.Cancelled("agent_stopped")),
        trace.Finished(attempt_span, pig_otel.Cancelled("agent_stopped")),
        trace.Finished(logical_span, pig_otel.Cancelled("agent_stopped")),
      ],
    )
  })
  let ended = trace.calls(recorder)
  runtime.stop(state)
  should.equal(trace.calls(recorder), ended)
  // A stopped named factory cannot restart owners under the removed root.
  should.equal(process.named(owners), Error(Nil))
}
