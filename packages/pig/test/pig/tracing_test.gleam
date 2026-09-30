//// Feature-level tracing contracts through a centralized OTP boundary harness.

import gleam/bit_array
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import jscheam/schema
import otel/context
import pig/agent/runtime
import pig/hooks
import pig/openai
import pig/provider
import pig/run
import pig/run_error
import pig/session_store
import pig/tool
import pig_otel
import pig_protocol/error
import pig_protocol/inference
import pig_protocol/message
import pig_protocol/thinking
import pig_protocol/tool_definition
import pig_transport
import support/tracing_harness as harness

fn parent() -> context.Context {
  pig_otel.ingress([
    #("traceparent", "00-11111111111111111111111111111111-2222222222222222-01"),
    #("baggage", "private=secret"),
  ])
}

fn attribute(span: harness.Snapshot, key: String) -> Result(String, Nil) {
  case list.find(span.attributes, fn(pair) { pair.0 == key }) {
    Ok(pair) -> Ok(pair.1)
    Error(_) -> Error(Nil)
  }
}

fn all_ended(spans: List(harness.Snapshot)) -> Nil {
  should.be_true(list.all(spans, fn(span) { span.ends == 1 }))
  should.be_false(string.contains(string.inspect(spans), "secret"))
}

pub fn acceptance_context_busy_streaming_and_continuation_test() {
  list.each([False, True], fn(supervised) {
    let entered = process.new_subject()
    let prov =
      provider.from_streaming(fn(_, emit) {
        let release = process.new_subject()
        process.send(entered, #(harness.current_id(), release))
        emit(provider.Delta(inference.TextDelta("secret delta")))
        let _ = harness.await(release)
        emit(provider.Finished(Ok(provider.from_message(harness.assistant()))))
      })
    harness.check_agent(
      prov,
      [],
      [],
      pig_otel.MetadataOnly,
      supervised,
      fn(agent) {
        let sink = process.new_subject()
        let handle =
          context.with_context(parent(), fn() { harness.stream(agent, sink) })
        let #(callback_id, release) = harness.await(entered)
        let assert [run_span, inference_span] = harness.snapshot()
        should.equal(run_span.parent, "2222222222222222")
        should.equal(attribute(run_span, "test.scope"), Ok("pig"))
        should.equal(attribute(run_span, "pig.run.id"), Ok(run.id(handle)))
        should.equal(inference_span.parent, run_span.id)
        should.equal(callback_id, inference_span.id)
        should.equal(
          attribute(inference_span, "gen_ai.request.model"),
          Error(Nil),
        )
        should.equal(
          attribute(inference_span, "gen_ai.provider.name"),
          Error(Nil),
        )
        should.equal(run_span.ends, 0)
        should.equal(inference_span.ends, 0)
        should.equal(harness.current_id(), "")
        should.equal(harness.start_again(agent), Error(run_error.Busy))
        should.equal(harness.snapshot(), [run_span, inference_span])
        process.send(release, Nil)
        should.equal(harness.collect(handle, sink), Ok(harness.assistant()))
        all_ended(harness.snapshot())
        let next_sink = process.new_subject()
        let next =
          context.with_context(
            pig_otel.ingress([
              #(
                "traceparent",
                "00-33333333333333333333333333333333-4444444444444444-01",
              ),
            ]),
            fn() { harness.continue_run(agent, next_sink) },
          )
        should.not_equal(run.id(next), run.id(handle))
        should.equal(harness.collect(next, next_sink), Ok(harness.assistant()))
        let assert [_, _, continuation] = harness.snapshot()
        should.equal(continuation.parent, "4444444444444444")
        should.equal(attribute(continuation, "pig.run.id"), Ok(run.id(next)))
        all_ended(harness.snapshot())
      },
    )
  })
}

pub fn disabled_preserves_explicit_callback_parent_without_spans_test() {
  list.each([False, True], fn(supervised) {
    let entered = process.new_subject()
    let prov =
      provider.from_buffered(fn(_) {
        process.send(entered, harness.current_id())
        Ok(provider.from_message(harness.assistant()))
      })
    harness.check_agent(prov, [], [], pig_otel.Disabled, supervised, fn(agent) {
      let result =
        context.with_context(parent(), fn() { harness.buffered(agent) })
      should.equal(result, Ok(harness.assistant()))
      should.equal(harness.await(entered), "2222222222222222")
      should.equal(harness.snapshot(), [])
      should.equal(harness.current_id(), "")
    })
  })
}

pub fn runtime_cancellation_owns_span_end_and_ignores_late_rounds_test() {
  list.each(
    [
      run_error.CallerRequested,
      run_error.DeadlineExceeded,
      run_error.ClientDisconnected,
      run_error.AgentStopped,
    ],
    fn(reason) {
      let entered = process.new_subject()
      let prov =
        provider.from_streaming(fn(_, _) {
          let release = process.new_subject()
          process.send(entered, Nil)
          let _ = harness.await(release)
          Nil
        })
      harness.check_runtime(prov, [], runtime.SessionDisabled, fn(subject) {
        let sink = process.new_subject()
        let assert Ok(handle) = runtime.stream(subject, "secret input", sink)
        let _ = harness.await(entered)
        run.cancel(handle, reason)
        let assert Error(run_error.Cancelled(observed)) =
          runtime.collect(handle, sink, 5000)
        should.equal(observed, reason)
        let before = harness.snapshot()
        all_ended(before)
        should.be_true(
          list.all(before, fn(span) {
            attribute(span, "pig.outcome") == Ok("cancelled")
          }),
        )
        process.send(
          subject,
          runtime.InferenceWorkerEvent(
            run.id(handle),
            1,
            provider.Finished(Ok(provider.from_message(harness.assistant()))),
          ),
        )
        process.send(
          subject,
          runtime.InferenceWorkerEvent(
            "late-run",
            9,
            provider.Finished(Error(error.Timeout)),
          ),
        )
        let _ = runtime.history(subject, 5000)
        should.equal(harness.snapshot(), before)
      })
    },
  )
}

fn gated_tool(
  name: String,
  entered: process.Subject(#(String, String)),
) -> tool.Tool {
  tool.Tool(
    tool_definition.ToolDefinition(name, "secret definition", schema.object([])),
    fn(call, _) {
      process.send(entered, #(tool.call_id(call), harness.current_id()))
      let _ = process.receive_forever(process.new_subject())
      Ok(gleam_json_string())
    },
  )
}

fn gleam_json_string() -> json.Json {
  json.string("secret result")
}

pub fn tool_sources_are_siblings_and_cancellation_closes_them_test() {
  let entered = process.new_subject()
  let calls = [
    message.ToolCall("one", "gate", "{\"secret\":1}"),
    message.ToolCall("two", "gate", "{\"secret\":2}"),
  ]
  let prov =
    provider.from_buffered(fn(_) {
      Ok(provider.from_message(message.Assistant("", calls, None, None)))
    })
  harness.check_agent(
    prov,
    [gated_tool("gate", entered)],
    [],
    pig_otel.MetadataOnly,
    False,
    fn(agent) {
      let sink = process.new_subject()
      let handle = harness.stream(agent, sink)
      let first = harness.await(entered)
      let second = harness.await(entered)
      let assert [run_span, inference_span, one, two] = harness.snapshot()
      should.equal(inference_span.ends, 1)
      should.equal(one.parent, run_span.id)
      should.equal(two.parent, run_span.id)
      should.equal(
        list.sort([first.1, second.1], string.compare),
        list.sort([one.id, two.id], string.compare),
      )
      should.equal(one.ends, 0)
      should.equal(two.ends, 0)
      run.cancel(handle, run_error.CallerRequested)
      should.equal(
        harness.collect(handle, sink),
        Error(run_error.Cancelled(run_error.CallerRequested)),
      )
      all_ended(harness.snapshot())
    },
  )
}

pub fn persistence_failure_fails_run_after_successful_inference_test() {
  let store = harness.unavailable_store()
  let prov =
    provider.from_buffered(fn(_) {
      Ok(provider.from_message(harness.assistant()))
    })
  harness.check_runtime(
    prov,
    [],
    runtime.SessionReady(store, None),
    fn(subject) {
      let assert Error(run_error.Session(session_store.Unavailable(_))) =
        runtime.run(subject, "secret input", 5000)
      let assert [run_span, inference_span] = harness.snapshot()
      should.equal(attribute(run_span, "error.type"), Ok("persistence_error"))
      should.equal(run_span.status, "error")
      should.equal(attribute(inference_span, "pig.outcome"), Ok("succeeded"))
      all_ended(harness.snapshot())
    },
  )
}

pub fn hook_exception_finalizes_run_and_preserves_original_failure_test() {
  let hook =
    hooks.new("throwing")
    |> hooks.on_before_inference(fn(_) { panic as "original hook failure" })
  let prov = provider.from_buffered(fn(_) { panic as "provider must not run" })
  harness.check_runtime(prov, [hook], runtime.SessionDisabled, fn(subject) {
    let assert Ok(owner) = process.subject_owner(subject)
    let monitor = process.monitor(owner)
    let sink = process.new_subject()
    let _ = runtime.stream(subject, "secret input", sink)
    let selector =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
    let assert Ok(down) = process.selector_receive(selector, 5000)
    should.be_true(string.contains(
      string.inspect(down),
      "original hook failure",
    ))
    let assert [run_span] = harness.snapshot()
    should.equal(attribute(run_span, "error.type"), Ok("callback_error"))
    all_ended([run_span])
  })
}

pub fn cleanup_failure_does_not_replace_original_exception_test() {
  let result = harness.double_failure()
  should.equal(result, "original hook failure")
}

pub fn both_openai_apis_use_inference_context_and_constructor_facts_test() {
  list.each([openai.ChatCompletions, openai.Responses], fn(api) {
    let seen = process.new_subject()
    let body = case api {
      openai.ChatCompletions ->
        "data: {\"id\":\"response-id\",\"model\":\"response-model\",\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
      openai.Responses ->
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"response-id\",\"model\":\"response-model\",\"status\":\"completed\",\"output\":[]}}\n\n"
    }
    let transport =
      pig_transport.Transport(
        sync: fn(_) { pig_transport.TransportError("unused") },
        stream: fn(request, events) {
          process.send(seen, #(pig_otel.ingress(request.headers), request.body))
          let control = process.new_subject()
          process.send(events, pig_transport.SourceReady(control))
          process.send(events, pig_transport.SourceHead(200, []))
          process.send(
            events,
            pig_transport.SourceChunk(bit_array.from_string(body)),
          )
          process.send(events, pig_transport.SourceDone)
        },
      )
    let prov =
      openai.provider_with_transport(
        api,
        "secret credential",
        "constructor-model",
        "http://example.test/v1",
        5000,
        transport,
      )
      |> openai.with_default_thinking_level(thinking.High)
      |> openai.with_http_timeout(5000)
    harness.check_agent(prov, [], [], pig_otel.MetadataOnly, False, fn(agent) {
      let assert Ok(_) =
        context.with_context(parent(), fn() { harness.buffered(agent) })
      let #(sent_context, body) = harness.await(seen)
      let assert [_, inference_span] = harness.snapshot()
      should.equal(harness.context_id(sent_context), inference_span.id)
      should.equal(
        attribute(inference_span, "gen_ai.request.model"),
        Ok("constructor-model"),
      )
      should.equal(
        attribute(inference_span, "gen_ai.response.model"),
        Ok("response-model"),
      )
      should.equal(
        attribute(inference_span, "pig.inference.thinking"),
        Ok("high"),
      )
      should.be_true(string.contains(body, "high"))
      all_ended(harness.snapshot())
    })
  })
}

pub fn deadline_disconnect_and_stop_trigger_terminal_cleanup_test() {
  list.each(
    [
      run_error.DeadlineExceeded,
      run_error.ClientDisconnected,
      run_error.AgentStopped,
    ],
    fn(reason) {
      let entered = process.new_subject()
      let prov =
        provider.from_streaming(fn(_, _) {
          process.send(entered, Nil)
          process.receive_forever(process.new_subject())
        })
      harness.check_runtime(prov, [], runtime.SessionDisabled, fn(subject) {
        let owner_ready = process.new_subject()
        let owner =
          process.spawn_unlinked(fn() {
            process.send(owner_ready, Nil)
            process.receive_forever(process.new_subject())
          })
        let _ = harness.await(owner_ready)
        let sink = process.new_subject()
        let assert Ok(handle) =
          runtime.stream_owned(subject, "secret input", sink, owner)
        let _ = harness.await(entered)
        case reason {
          run_error.DeadlineExceeded -> {
            should.equal(
              runtime.collect(handle, sink, 0),
              Error(run_error.Cancelled(reason)),
            )
            // The caller's timeout is not the cleanup boundary; this actor reply is.
            let _ = runtime.history(subject, 5000)
            Nil
          }
          run_error.ClientDisconnected -> {
            process.kill(owner)
            should.equal(
              runtime.collect(handle, sink, 5000),
              Error(run_error.Cancelled(reason)),
            )
          }
          run_error.AgentStopped -> {
            runtime.stop(subject)
            should.equal(
              runtime.collect(handle, sink, 5000),
              Error(run_error.Cancelled(reason)),
            )
          }
          _ -> panic as "unexpected case"
        }
        process.kill(owner)
        all_ended(harness.snapshot())
        should.be_true(
          list.all(harness.snapshot(), fn(span) {
            span.status == "error"
            && attribute(span, "pig.outcome") == Ok("cancelled")
          }),
        )
      })
    },
  )
}

pub fn late_run_and_round_do_not_finish_new_inference_test() {
  let entered = process.new_subject()
  let prov =
    provider.from_streaming(fn(_, emit) {
      let release = process.new_subject()
      process.send(entered, release)
      let _ = harness.await(release)
      emit(provider.Finished(Ok(provider.from_message(harness.assistant()))))
    })
  harness.check_runtime(prov, [], runtime.SessionDisabled, fn(subject) {
    let first_sink = process.new_subject()
    let assert Ok(first) = runtime.stream(subject, "secret input", first_sink)
    let _ = harness.await(entered)
    run.cancel(first, run_error.CallerRequested)
    let assert Error(_) = runtime.collect(first, first_sink, 5000)
    let next_sink = process.new_subject()
    let assert Ok(next) = runtime.stream(subject, "secret input", next_sink)
    let release = harness.await(entered)
    let before = harness.snapshot()
    process.send(
      subject,
      runtime.InferenceWorkerEvent(
        run.id(first),
        1,
        provider.Finished(Error(error.Timeout)),
      ),
    )
    process.send(
      subject,
      runtime.InferenceWorkerEvent(
        run.id(next),
        99,
        provider.Finished(Error(error.Timeout)),
      ),
    )
    let _ = runtime.history(subject, 5000)
    should.equal(harness.snapshot(), before)
    process.send(release, Nil)
    should.equal(
      runtime.collect(next, next_sink, 5000),
      Ok(harness.assistant()),
    )
    all_ended(harness.snapshot())
  })
}

pub fn blocked_lookup_decode_and_handler_failure_have_bounded_status_test() {
  list.each(
    [
      #("missing", "{}", "tool_not_found"),
      #("fail", "invalid", "invalid_arguments"),
      #("fail", "{}", "tool_error"),
      #("blocked", "{}", "tool_blocked"),
    ],
    fn(test_case) {
      let #(name, arguments, category) = test_case
      let call = message.ToolCall("call-1", name, arguments)
      let prov =
        provider.from_buffered(fn(request) {
          case list.last(request.messages) {
            Ok(message.Tool(_, _)) ->
              Ok(provider.from_message(harness.assistant()))
            _ ->
              Ok(
                provider.from_message(message.Assistant("", [call], None, None)),
              )
          }
        })
      let fail =
        tool.Tool(
          tool_definition.ToolDefinition(
            "fail",
            "secret definition",
            schema.object([]),
          ),
          fn(_, _) { Error(tool.ToolError("secret handler error")) },
        )
      let hook =
        hooks.new("blocker")
        |> hooks.on_tool_call(fn(event) {
          case event.tool_name {
            "blocked" -> hooks.BlockTool("secret reason")
            _ -> hooks.AllowTool
          }
        })
      harness.check_agent(
        prov,
        [fail],
        [hook],
        pig_otel.MetadataOnly,
        False,
        fn(agent) {
          should.equal(harness.buffered(agent), Ok(harness.assistant()))
          let spans = harness.snapshot()
          let assert [run_span, _, tool_span, _] = spans
          should.equal(attribute(tool_span, "error.type"), Ok(category))
          should.equal(tool_span.status, "error")
          should.equal(tool_span.parent, run_span.id)
          should.equal(run_span.status, "unset")
          all_ended(spans)
        },
      )
    },
  )
}

pub fn api_only_without_sdk_preserves_business_result_and_parent_test() {
  let entered = process.new_subject()
  let prov =
    provider.from_buffered(fn(_) {
      process.send(entered, harness.current_id())
      Ok(provider.from_message(harness.assistant()))
    })
  harness.check_no_sdk(prov, fn(agent) {
    should.equal(
      context.with_context(parent(), fn() { harness.buffered(agent) }),
      Ok(harness.assistant()),
    )
    should.equal(harness.await(entered), "2222222222222222")
    should.equal(harness.snapshot(), [])
    should.equal(harness.current_id(), "")
  })
}

pub fn durable_recovery_is_a_fresh_run_and_pending_rejection_has_no_span_test() {
  let #(store, cleanup) = harness.recoverable_store()
  let prov =
    provider.from_buffered(fn(_) {
      Ok(provider.from_message(harness.assistant()))
    })
  harness.check_runtime(
    prov,
    [],
    runtime.SessionReady(store, None),
    fn(subject) {
      let sink = process.new_subject()
      let assert Ok(first) = runtime.stream(subject, "secret input", sink)
      let assert Error(run_error.Session(_)) =
        runtime.collect(first, sink, 5000)
      let failed = harness.snapshot()
      all_ended(failed)
      let assert Error(run_error.Rejected(_)) =
        runtime.stream(subject, "rejected", process.new_subject())
      should.equal(harness.snapshot(), failed)
      let next_sink = process.new_subject()
      let assert Ok(next) =
        context.with_context(parent(), fn() {
          runtime.stream_continue(subject, next_sink)
        })
      should.not_equal(run.id(first), run.id(next))
      should.equal(
        runtime.collect(next, next_sink, 5000),
        Ok(harness.assistant()),
      )
      let assert [_, _, recovered] = harness.snapshot()
      should.equal(recovered.parent, "2222222222222222")
      should.equal(attribute(recovered, "pig.run.id"), Ok(run.id(next)))
      should.equal(attribute(recovered, "pig.outcome"), Ok("succeeded"))
      all_ended(harness.snapshot())
    },
  )
  cleanup()
}

pub fn provider_failures_export_only_bounded_categories_test() {
  list.each(
    [
      #(error.Timeout, "timeout"),
      #(error.RateLimited, "rate_limited"),
      #(error.ApiError("secret remote error"), "provider_error"),
      #(error.InvalidResponse("secret malformed body"), "provider_error"),
    ],
    fn(test_case) {
      let #(error, category) = test_case
      let prov = provider.from_buffered(fn(_) { Error(error) })
      harness.check_agent(prov, [], [], pig_otel.MetadataOnly, False, fn(agent) {
        should.equal(harness.buffered(agent), Error(run_error.Inference(error)))
        let spans = harness.snapshot()
        should.equal(list.length(spans), 2)
        should.be_true(
          list.all(spans, fn(span) {
            span.status == "error"
            && attribute(span, "error.type") == Ok(category)
          }),
        )
        all_ended(spans)
      })
    },
  )
}

pub fn throwing_cancellation_hook_cannot_skip_or_rewrite_span_cleanup_test() {
  let entered = process.new_subject()
  let prov =
    provider.from_streaming(fn(_, _) {
      process.send(entered, Nil)
      process.receive_forever(process.new_subject())
    })
  let hook =
    hooks.new("throwing")
    |> hooks.on_error(fn(_) { panic as "original cancellation hook failure" })
  harness.check_runtime(prov, [hook], runtime.SessionDisabled, fn(subject) {
    let assert Ok(owner) = process.subject_owner(subject)
    let monitor = process.monitor(owner)
    let sink = process.new_subject()
    let assert Ok(handle) = runtime.stream(subject, "secret input", sink)
    let _ = harness.await(entered)
    run.cancel(handle, run_error.CallerRequested)
    let selector =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
    let assert Ok(down) = process.selector_receive(selector, 5000)
    should.be_true(string.contains(
      string.inspect(down),
      "original cancellation hook failure",
    ))
    should.equal(
      harness.collect(handle, sink),
      Error(run_error.Cancelled(run_error.CallerRequested)),
    )
    let spans = harness.snapshot()
    should.equal(list.length(spans), 2)
    should.be_true(
      list.all(spans, fn(span) {
        attribute(span, "pig.outcome") == Ok("cancelled")
      }),
    )
    all_ended(spans)
  })
}

fn monitored_gated_tool(
  entered: process.Subject(#(String, String, process.Subject(Nil))),
) -> tool.Tool {
  tool.Tool(
    tool_definition.ToolDefinition(
      "gate",
      "secret definition",
      schema.object([]),
    ),
    fn(call, _) {
      let control = process.new_subject()
      process.send(entered, #(tool.call_id(call), harness.current_id(), control))
      let _ = process.receive_forever(control)
      Ok(gleam_json_string())
    },
  )
}

pub fn throwing_tool_cancellation_hook_cannot_strand_sources_or_duplicate_terminals_test() {
  list.each(
    [
      #(run_error.CallerRequested, "cancelled"),
      #(run_error.DeadlineExceeded, "deadline_exceeded"),
      #(run_error.ClientDisconnected, "client_disconnected"),
      #(run_error.AgentStopped, "agent_stopped"),
    ],
    fn(test_case) {
      let #(reason, category) = test_case
      let entered = process.new_subject()
      let hook_entered = process.new_subject()
      let calls = [
        message.ToolCall("one", "gate", "{}"),
        message.ToolCall("two", "gate", "{}"),
      ]
      let response =
        provider.from_message(message.Assistant("", calls, None, None))
      let prov = provider.from_buffered(fn(_) { Ok(response) })
      let hook =
        hooks.new("throwing-first-result")
        |> hooks.on_tool_result(fn(event) {
          process.send(hook_entered, event)
          panic as "original tool cancellation hook failure"
        })
      harness.check_runtime_with_tools(
        prov,
        [monitored_gated_tool(entered)],
        [hook],
        runtime.SessionDisabled,
        fn(subject) {
          let runtime_retired = harness.watch_source(subject)
          let sink = process.new_subject()
          let assert Ok(handle) =
            context.with_context(parent(), fn() {
              runtime.stream(subject, "secret input", sink)
            })
          let first = harness.await(entered)
          let second = harness.await(entered)
          let first_retired = harness.watch_source(first.2)
          let second_retired = harness.watch_source(second.2)
          let assert [run_span, inference_span, one, two] = harness.snapshot()
          should.equal(run_span.parent, "2222222222222222")
          should.equal(inference_span.parent, run_span.id)
          should.equal(inference_span.ends, 1)
          should.equal(one.parent, run_span.id)
          should.equal(two.parent, run_span.id)
          should.equal(attribute(one, "gen_ai.tool.call.id"), Ok("one"))
          should.equal(attribute(two, "gen_ai.tool.call.id"), Ok("two"))
          should.equal(list.sort([first.0, second.0], string.compare), [
            "one",
            "two",
          ])
          should.equal(
            list.sort([first.1, second.1], string.compare),
            list.sort([one.id, two.id], string.compare),
          )
          should.equal(run_span.ends, 0)
          should.equal(one.ends, 0)
          should.equal(two.ends, 0)
          run.cancel(handle, reason)
          // Runtime DOWN is not the worker retirement or terminal-result boundary.
          let down = harness.await(runtime_retired)
          should.equal(
            harness.exit_message(down),
            "original tool cancellation hook failure",
          )
          should.equal(harness.await(first_retired), process.Killed)
          should.equal(harness.await(second_retired), process.Killed)
          should.equal(
            harness.collect(handle, sink),
            Error(run_error.Cancelled(reason)),
          )
          let event = harness.await(hook_entered)
          should.equal(event.tool_call_id, "one")
          should.equal(event.is_error, True)
          should.equal(event.result, "Tool error: Tool cancelled")
          should.equal(harness.drain(hook_entered), [])
          let assert [ended_run, ended_inference, ended_one, ended_two] =
            harness.snapshot()
          should.equal(ended_inference, inference_span)
          list.each([ended_run, ended_one, ended_two], fn(span) {
            should.equal(span.status, "error")
            should.equal(attribute(span, "pig.outcome"), Ok("cancelled"))
            should.equal(attribute(span, "error.type"), Ok(category))
          })
          all_ended(harness.snapshot())
          let assert [one_call, two_call] = calls
          // Inspect the entire sink after all DOWN ACKs: exactly one finish per
          // tool, followed by exactly one terminal, even though the first hook died.
          should.equal(harness.drain(sink), [
            run.RunStarted,
            run.InferenceStarted(1),
            run.InferenceFinished(1, Ok(response)),
            run.ToolStarted(1, one_call),
            run.ToolStarted(1, two_call),
            run.ToolFinished(1, one_call, Error(tool.Cancelled)),
            run.ToolFinished(1, two_call, Error(tool.Cancelled)),
            run.Cancelled(reason),
          ])
          should.equal(harness.current_id(), "")
        },
      )
    },
  )
}

pub fn provider_callback_panic_is_bounded_failure_and_runtime_remains_responsive_test() {
  list.each([False, True], fn(streaming) {
    let entered = process.new_subject()
    let callback = fn(_) {
      let control = process.new_subject()
      process.send(entered, #(harness.current_id(), control))
      case harness.await(control) {
        False -> panic as "secret provider callback failure"
        True -> Ok(provider.from_message(harness.assistant()))
      }
    }
    let prov = case streaming {
      False -> provider.from_buffered(callback)
      True ->
        provider.from_streaming(fn(request, emit) {
          emit(provider.Finished(callback(request)))
        })
    }
    harness.check_runtime(prov, [], runtime.SessionDisabled, fn(subject) {
      context.with_context(parent(), fn() {
        let sink = process.new_subject()
        let assert Ok(handle) = runtime.stream(subject, "secret input", sink)
        should.equal(harness.current_id(), "2222222222222222")
        let #(callback_id, control) = harness.await(entered)
        let source_retired = harness.watch_source(control)
        let assert [run_span, inference_span] = harness.snapshot()
        should.equal(run_span.parent, "2222222222222222")
        should.equal(inference_span.parent, run_span.id)
        should.equal(callback_id, inference_span.id)
        should.equal(run_span.ends, 0)
        should.equal(inference_span.ends, 0)
        process.send(control, False)
        should.equal(
          harness.exit_message(harness.await(source_retired)),
          "secret provider callback failure",
        )
        let failure =
          error.InvalidResponse(
            "Provider process exited without a terminal event",
          )
        should.equal(
          runtime.collect(handle, sink, 5000),
          Error(run_error.Inference(failure)),
        )
        should.equal(harness.current_id(), "2222222222222222")
        // A provider source panic is normalized, not an actor crash. Its reply
        // also fences the failure sink before we check terminal cardinality.
        should.equal(runtime.history(subject, 5000), [
          message.User("secret input"),
        ])
        let failed = harness.snapshot()
        let assert [failed_run, failed_inference] = failed
        should.equal(failed_run.id, run_span.id)
        should.equal(failed_inference.id, inference_span.id)
        list.each(failed, fn(span) {
          should.equal(span.status, "error")
          should.equal(attribute(span, "pig.outcome"), Ok("failed"))
          should.equal(attribute(span, "error.type"), Ok("provider_error"))
        })
        all_ended(failed)
        should.equal(harness.drain(sink), [
          run.RunStarted,
          run.InferenceStarted(1),
          run.InferenceFinished(1, Error(failure)),
          run.Failed(run_error.Inference(failure)),
        ])
        let next_sink = process.new_subject()
        let assert Ok(next) = runtime.stream_continue(subject, next_sink)
        should.not_equal(run.id(next), run.id(handle))
        let #(next_callback_id, next_control) = harness.await(entered)
        let assert [_, _, next_run, next_inference] = harness.snapshot()
        should.equal(next_run.parent, "2222222222222222")
        should.equal(next_inference.parent, next_run.id)
        should.equal(next_callback_id, next_inference.id)
        should.equal(harness.current_id(), "2222222222222222")
        process.send(next_control, True)
        should.equal(
          runtime.collect(next, next_sink, 5000),
          Ok(harness.assistant()),
        )
        should.equal(runtime.history(subject, 5000), [
          message.User("secret input"),
          harness.assistant(),
        ])
        should.equal(harness.drain(next_sink), [
          run.RunStarted,
          run.InferenceStarted(1),
          run.InferenceFinished(
            1,
            Ok(provider.from_message(harness.assistant())),
          ),
          run.Completed(provider.from_message(harness.assistant())),
        ])
        let assert [
          unchanged_run,
          unchanged_inference,
          recovered_run,
          recovered_inference,
        ] = harness.snapshot()
        should.equal([unchanged_run, unchanged_inference], failed)
        list.each([recovered_run, recovered_inference], fn(span) {
          should.equal(span.status, "unset")
          should.equal(attribute(span, "pig.outcome"), Ok("succeeded"))
          should.equal(attribute(span, "error.type"), Error(Nil))
        })
        all_ended(harness.snapshot())
        should.equal(harness.current_id(), "2222222222222222")
      })
      should.equal(harness.current_id(), "")
    })
  })
}
