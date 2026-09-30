//// All test boundary calls live here; matrices express facts and expectations.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None}
import gleeunit/should
import otel/attribute.{type Attribute, type Value}
import otel/context
import otel/trace
import pig_otel
import pig_protocol/inference.{type InferenceMetadata}

pub fn check_operation(
  operation: pig_otel.Operation,
  expected_name: String,
  expected_kind: trace.SpanKind,
  expected_attributes: List(#(String, Value)),
) -> Nil {
  let #(name, kind, attributes) = pig_otel.describe(operation)
  should.equal(#(name, kind), #(expected_name, expected_kind))
  should.equal(attributes, make_attributes(expected_attributes))
}

pub fn check_response(
  metadata: InferenceMetadata,
  expected: List(#(String, Value)),
) -> Nil {
  should.equal(
    pig_otel.response_attributes(metadata),
    make_attributes(expected),
  )
}

pub fn check_terminal(
  outcome: pig_otel.Outcome,
  expected_status: trace.Status,
  expected: List(#(String, Value)),
) -> Nil {
  let #(status, attributes) = pig_otel.terminal(outcome)
  should.equal(status, expected_status)
  should.equal(attributes, make_attributes(expected))
}

fn make_attributes(values: List(#(String, Value))) -> List(Attribute) {
  list.map(values, fn(pair) {
    let assert Ok(key) = attribute.key(pair.0)
    attribute.Attribute(key, pair.1)
  })
}

/// Test both exported backend forms against the same parent-preserving contract.
pub fn check_disabled(use_policy: Bool) -> Nil {
  use <- with_composite
  let parent = pig_otel.ingress([#("traceparent", parent_header)])
  let #(backend, calls) =
    lookup_calls(fn() {
      case use_policy {
        True -> pig_otel.backend(pig_otel.Disabled, unowned_marker())
        False -> pig_otel.disabled()
      }
    })
  should.equal(calls, 0)
  let span = pig_otel.start(backend, parent, pig_otel.Run(None, "run"))
  should.equal(pig_otel.context(span), parent)
  pig_otel.annotate(span, [
    pig_otel.bool_attribute("gen_ai.request.stream", True),
  ])
  pig_otel.finish(span, pig_otel.Cancelled("deadline_exceeded"))
  should.equal(pig_otel.context(span), parent)
  should.equal(pig_otel.outbound(pig_otel.context(span), stale_headers()), [
    #("x-keep", "kept"),
    #("traceparent", parent_header),
  ])
}

pub const parent_header = "00-11111111111111111111111111111111-2222222222222222-01"

const other_header = "00-33333333333333333333333333333333-4444444444444444-01"

pub fn stale_headers() -> List(#(String, String)) {
  [
    #("TraceParent", "stale"),
    #("traceparent", "duplicate"),
    #("TrAcEsTaTe", "stale=value"),
    #("tracestate", "duplicate=value"),
    #("Baggage", "private=value"),
    #("bAgGaGe", "malformed;;;"),
    #("x-keep", "kept"),
  ]
}

pub fn check_propagation() -> Nil {
  use <- with_composite
  let before = context.current()
  let parent =
    pig_otel.ingress([
      #("TraceParent", parent_header),
      #("TrAcEsTaTe", "vendor=public"),
      #("Baggage", "private=value"),
      #("baggage", "malformed;;;"),
    ])
  should.equal(context.current(), before)
  should.equal(has_baggage(parent), False)
  let ambient = with_baggage(pig_otel.ingress([#("traceparent", other_header)]))
  use <- context.with_context(ambient)
  let outgoing = pig_otel.outbound(parent, stale_headers())
  should.equal(outgoing, [
    #("x-keep", "kept"),
    #("traceparent", parent_header),
    #("tracestate", "vendor=public"),
  ])
  should.equal(context.current(), ambient)
  // Injection would recreate baggage from this explicit context without the
  // post-injection filter; ambient-only hygiene is insufficient.
  should.equal(pig_otel.outbound(with_baggage(parent), []), [
    #("traceparent", parent_header),
    #("tracestate", "vendor=public"),
  ])
}

pub fn check_invalid_propagation() -> Nil {
  use <- with_composite
  list.each(
    ["", "bad", "00-00000000000000000000000000000000-2222222222222222-01"],
    fn(value) {
      let parent = pig_otel.ingress([#("traceparent", value)])
      should.equal(pig_otel.outbound(parent, stale_headers()), [
        #("x-keep", "kept"),
      ])
    },
  )
}

pub fn check_lookup_failure() -> Nil {
  let parent = context.current()
  let #(backend, diagnostics) =
    capture_diagnostics(fn() {
      pig_otel.backend(pig_otel.MetadataOnly, unowned_marker())
    })
  should.equal(diagnostics, [
    "Pig tracing disabled: marker application not found",
  ])
  let #(span, starts) =
    start_calls(fn() {
      pig_otel.start(backend, parent, pig_otel.Run(None, "run"))
    })
  should.equal(starts, 0)
  should.equal(pig_otel.context(span), parent)
  pig_otel.finish(span, pig_otel.Failed("a raw private failure"))
}

pub fn check_no_sdk() -> Nil {
  should.be_true(sdk_absent())
  let before = context.current()
  let backend = pig_otel.backend(pig_otel.MetadataOnly, application_marker)
  let #(spans, starts) =
    start_calls(fn() {
      list.map(
        [
          pig_otel.Run(None, "run"),
          pig_otel.Inference(pig_otel.Responses, None, None),
          pig_otel.Tool("weather", "call"),
          pig_otel.HttpServer("/v1/responses"),
          pig_otel.HttpAttempt("primary"),
        ],
        fn(operation) {
          let span = pig_otel.start(backend, before, operation)
          let _ = context.with_context(pig_otel.context(span), fn() { 42 })
          pig_otel.annotate(span, [
            pig_otel.int_attribute("http.response.status_code", 200),
          ])
          pig_otel.finish(span, pig_otel.Succeeded)
          pig_otel.finish(span, pig_otel.Failed("late private error"))
          span
        },
      )
    })
  should.equal(starts, 5)
  should.equal(list.length(spans), 5)
  should.equal(context.current(), before)
}

pub fn application_marker() -> Nil {
  Nil
}

@external(erlang, "pig_otel_test_ffi", "with_composite")
pub fn with_composite(work: fn() -> a) -> a

@external(erlang, "pig_otel_test_ffi", "unowned_marker")
fn unowned_marker() -> fn() -> Nil

@external(erlang, "pig_otel_test_ffi", "with_baggage")
fn with_baggage(parent: context.Context) -> context.Context

@external(erlang, "pig_otel_test_ffi", "has_baggage")
fn has_baggage(parent: context.Context) -> Bool

@external(erlang, "pig_otel_test_ffi", "lookup_calls")
fn lookup_calls(work: fn() -> a) -> #(a, Int)

@external(erlang, "pig_otel_test_ffi", "start_calls")
fn start_calls(work: fn() -> a) -> #(a, Int)

@external(erlang, "pig_otel_test_ffi", "capture_diagnostics")
fn capture_diagnostics(work: fn() -> a) -> #(a, List(String))

@external(erlang, "pig_otel_test_ffi", "sdk_absent")
fn sdk_absent() -> Bool

/// Fixture loading is an outer disk boundary; check_headers remains pure.
pub fn header_fixtures() -> List(
  #(
    String,
    List(#(String, String)),
    List(#(String, String)),
    List(#(String, String)),
  ),
) {
  let assert Ok(contents) = read_fixture("test_data/headers.json")
  let pair = {
    use key <- decode.field(0, decode.string)
    use value <- decode.field(1, decode.string)
    decode.success(#(key, value))
  }
  let headers = decode.list(pair)
  let row = {
    use name <- decode.field("name", decode.string)
    use input <- decode.field("input", headers)
    use scrubbed <- decode.field("scrubbed", headers)
    use without_baggage <- decode.field("without_baggage", headers)
    decode.success(#(name, input, scrubbed, without_baggage))
  }
  let assert Ok(rows) = json.parse(contents, decode.list(row))
  rows
}

pub fn check_headers(
  name: String,
  input: List(#(String, String)),
  scrubbed: List(#(String, String)),
  without_baggage: List(#(String, String)),
) -> Nil {
  should.equal(#(name, pig_otel.scrub_propagation(input)), #(name, scrubbed))
  should.equal(#(name, pig_otel.drop_baggage(input)), #(name, without_baggage))
}

@external(erlang, "pig_otel_test_ffi", "read_fixture")
fn read_fixture(path: String) -> Result(String, Nil)

pub fn check_callback_failure() -> Nil {
  let before = context.current()
  use <- with_composite
  let parent = pig_otel.ingress([#("traceparent", parent_header)])
  let span =
    pig_otel.start(
      pig_otel.disabled(),
      parent,
      pig_otel.Tool("weather", "call1"),
    )
  let caught =
    catch_work(fn() {
      context.with_context(pig_otel.context(span), fn() {
        should.equal(context.current(), parent)
        panic as "expected private callback failure"
      })
    })
  should.equal(caught, Error(Nil))
  pig_otel.finish(span, pig_otel.Failed("callback_error"))
  should.equal(context.current(), before)
}

@external(erlang, "pig_otel_test_ffi", "catch_work")
fn catch_work(work: fn() -> a) -> Result(a, Nil)
