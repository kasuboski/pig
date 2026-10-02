//// Official SDK test-host boundary; no collector, sleeps, or PID assertions.

import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import otel/attribute.{type Value, IntValue, StringValue}
import otel/context
import pig_otel
import pig_otel_sdk_recording
import pig_protocol/inference

/// A synchronous export snapshot including scope and parentage.
pub type Snapshot {
  Snapshot(
    name: String,
    kind: String,
    trace_id: String,
    span_id: String,
    parent_id: String,
    status: String,
    scope: String,
    scope_version: String,
    schema_url: String,
    attributes: List(#(String, Value)),
  )
}

pub fn check_lifecycle() -> Nil {
  use <- with_sdk
  let before = context.current()
  let backend =
    pig_otel.backend(pig_otel.MetadataOnly, pig_otel_sdk_recording.marker)
  let parent =
    pig_otel.ingress([
      #(
        "traceparent",
        "00-11111111111111111111111111111111-2222222222222222-01",
      ),
      #("baggage", "private=not-allowed"),
    ])
  let run =
    pig_otel.start(backend, parent, pig_otel.Run(Some("planner"), "accepted"))
  let inference_span =
    pig_otel.start(
      backend,
      pig_otel.context(run),
      pig_otel.Inference(pig_otel.Responses, Some("openai"), Some("requested")),
    )
  should.equal(snapshot(), [])
  let meta =
    inference.InferenceMetadata(
      Some("response1"),
      Some("actual"),
      None,
      Some(100),
      Some(50),
      Some(40),
    )
  pig_otel.annotate(inference_span, pig_otel.response_attributes(meta))
  pig_otel.finish(inference_span, pig_otel.Succeeded)
  let tool =
    pig_otel.start(
      backend,
      pig_otel.context(run),
      pig_otel.Tool("weather", "call1"),
    )
  let callback_result =
    context.with_context(pig_otel.context(tool), fn() {
      should.equal(context.current(), pig_otel.context(tool))
      42
    })
  should.equal(callback_result, 42)
  should.equal(context.current(), before)
  pig_otel.finish(tool, pig_otel.Failed("raw private tool error"))
  pig_otel.finish(run, pig_otel.Cancelled("client_disconnected"))
  // Late updates and repeated terminals cannot change exported results.
  pig_otel.annotate(inference_span, [
    pig_otel.int_attribute("gen_ai.usage.input_tokens", 999),
  ])
  pig_otel.finish(inference_span, pig_otel.Failed("provider_error"))
  pig_otel.finish(tool, pig_otel.Succeeded)
  pig_otel.finish(run, pig_otel.Succeeded)
  let spans = snapshot()
  should.equal(list.length(spans), 3)
  let run_record = find(spans, "invoke_agent planner")
  let inference_record = find(spans, "chat requested")
  let tool_record = find(spans, "execute_tool weather")
  should.equal(#(run_record.trace_id, run_record.parent_id), #(
    "11111111111111111111111111111111",
    "2222222222222222",
  ))
  should.equal(#(inference_record.parent_id, tool_record.parent_id), #(
    run_record.span_id,
    run_record.span_id,
  ))
  should.equal(#(run_record.kind, inference_record.kind, tool_record.kind), #(
    "internal",
    "client",
    "internal",
  ))
  should.equal(
    #(run_record.status, inference_record.status, tool_record.status),
    #("error", "unset", "error"),
  )
  should.equal(
    #(run_record.scope, run_record.scope_version, run_record.schema_url),
    #("pig_otel_sdk_recording", "0.1.0", ""),
  )
  should.equal(inference_record.scope, run_record.scope)
  should.equal(tool_record.scope, run_record.scope)
  should.equal(
    dict.from_list(inference_record.attributes),
    dict.from_list([
      #("gen_ai.operation.name", StringValue("chat")),
      #("gen_ai.provider.name", StringValue("openai")),
      #("gen_ai.request.model", StringValue("requested")),
      #("openai.api.type", StringValue("responses")),
      #("gen_ai.response.id", StringValue("response1")),
      #("gen_ai.response.model", StringValue("actual")),
      #("gen_ai.usage.input_tokens", IntValue(100)),
      #("gen_ai.usage.output_tokens", IntValue(50)),
      #("gen_ai.usage.cache_read.input_tokens", IntValue(40)),
      #("pig.outcome", StringValue("succeeded")),
    ]),
  )
  let tool_attributes = dict.from_list(tool_record.attributes)
  should.equal(
    dict.get(tool_attributes, "error.type"),
    Ok(StringValue("_OTHER")),
  )
  should.equal(
    dict.get(dict.from_list(run_record.attributes), "error.type"),
    Ok(StringValue("client_disconnected")),
  )
  // Exported rows are exact, hence no prompts, bodies, auth, or baggage fields.
}

pub fn check_disabled() -> Nil {
  use <- with_sdk
  let parent = context.current()
  let span =
    pig_otel.start(
      pig_otel.backend(pig_otel.Disabled, pig_otel_sdk_recording.marker),
      parent,
      pig_otel.Tool("weather", "call1"),
    )
  pig_otel.finish(span, pig_otel.Failed("tool_error"))
  should.equal(pig_otel.context(span), parent)
  should.equal(snapshot(), [])
}

pub fn check_unsampled() -> Nil {
  use <- with_sdk
  let backend =
    pig_otel.backend(pig_otel.MetadataOnly, pig_otel_sdk_recording.marker)
  let parent =
    pig_otel.ingress([
      #(
        "traceparent",
        "00-11111111111111111111111111111111-2222222222222222-00",
      ),
    ])
  let span =
    pig_otel.start(
      backend,
      parent,
      pig_otel.Inference(pig_otel.ChatCompletions, None, None),
    )
  let output =
    context.with_context(pig_otel.context(span), fn() { "business-success" })
  pig_otel.finish(span, pig_otel.Succeeded)
  should.equal(output, "business-success")
  should.equal(snapshot(), [])
}

pub fn check_absent_metadata() -> Nil {
  use <- with_sdk
  let backend =
    pig_otel.backend(pig_otel.MetadataOnly, pig_otel_sdk_recording.marker)
  let span =
    pig_otel.start(
      backend,
      context.current(),
      pig_otel.Inference(pig_otel.Custom, None, None),
    )
  let metadata = inference.default_metadata()
  pig_otel.annotate(span, pig_otel.response_attributes(metadata))
  pig_otel.finish(span, pig_otel.Succeeded)
  let record = find(snapshot(), "chat")
  should.equal(
    dict.from_list(record.attributes),
    dict.from_list([
      #("gen_ai.operation.name", StringValue("chat")),
      #("pig.outcome", StringValue("succeeded")),
    ]),
  )
}

fn find(spans: List(Snapshot), name: String) -> Snapshot {
  let assert Ok(span) = list.find(spans, fn(span) { span.name == name })
  span
}

@external(erlang, "pig_otel_recording_ffi", "with_sdk")
fn with_sdk(work: fn() -> a) -> a

@external(erlang, "pig_otel_recording_ffi", "snapshot")
fn snapshot() -> List(Snapshot)

pub fn check_http_hierarchy() -> Nil {
  use <- with_sdk
  let backend =
    pig_otel.backend(pig_otel.MetadataOnly, pig_otel_sdk_recording.marker)
  let server =
    pig_otel.start(
      backend,
      context.current(),
      pig_otel.HttpServer("/v1/responses"),
    )
  let logical =
    pig_otel.start(
      backend,
      pig_otel.context(server),
      pig_otel.Inference(pig_otel.Responses, None, None),
    )
  let first =
    pig_otel.start(
      backend,
      pig_otel.context(logical),
      pig_otel.HttpAttempt("first"),
    )
  let header = dict.from_list(pig_otel.outbound(pig_otel.context(first), []))
  pig_otel.finish(first, pig_otel.Failed("transport_error"))
  let second =
    pig_otel.start(
      backend,
      pig_otel.context(logical),
      pig_otel.HttpAttempt("second"),
    )
  pig_otel.annotate(second, [
    pig_otel.int_attribute("http.response.status_code", 200),
  ])
  pig_otel.finish(second, pig_otel.Succeeded)
  pig_otel.finish(logical, pig_otel.Succeeded)
  pig_otel.finish(server, pig_otel.Succeeded)
  let spans = snapshot()
  should.equal(list.length(spans), 4)
  let server_record = find(spans, "POST /v1/responses")
  let logical_record = find(spans, "chat")
  let attempts = list.filter(spans, fn(span) { span.name == "POST" })
  should.equal(list.length(attempts), 2)
  should.equal(#(server_record.kind, logical_record.kind), #("server", "client"))
  should.equal(logical_record.parent_id, server_record.span_id)
  should.equal(logical_record.status, "unset")
  list.each(attempts, fn(attempt) {
    should.equal(attempt.kind, "client")
    should.equal(attempt.parent_id, logical_record.span_id)
    let attributes = dict.from_list(attempt.attributes)
    case dict.get(attributes, "pig.proxy.target.id") {
      Ok(StringValue("first")) -> {
        should.equal(attempt.status, "error")
        should.equal(
          dict.get(attributes, "error.type"),
          Ok(StringValue("transport_error")),
        )
        should.equal(
          dict.get(header, "traceparent"),
          Ok("00-" <> attempt.trace_id <> "-" <> attempt.span_id <> "-01"),
        )
      }
      _ -> {
        should.equal(attempt.status, "unset")
        should.equal(
          dict.get(attributes, "http.response.status_code"),
          Ok(IntValue(200)),
        )
      }
    }
  })
}
