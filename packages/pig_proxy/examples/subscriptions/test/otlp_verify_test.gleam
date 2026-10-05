import gleam/bit_array
import gleam/int
import gleam/list
import gleeunit/should
import support/otlp_verify.{type Span, Number, Span, Text, Values}

pub fn valid_metadata_fixture_test() {
  should.equal(check(fixture(False), False), Ok(Nil))
}

pub fn valid_capture_fixture_test() {
  should.equal(check(fixture(True), True), Ok(Nil))
}

pub fn wrong_count_test() {
  should.equal(check([], False), Error(otlp_verify.WrongCount(20, 0)))
}

pub fn duplicate_identity_test() {
  let spans = fixture(False)
  let assert [first, _, ..rest] = spans
  should.equal(
    check([first, first, ..rest], False),
    Error(otlp_verify.DuplicateSpanIds),
  )
}

pub fn path_resource_scope_and_nested_privacy_test() {
  let spans = fixture(False)
  let assert Ok(first) = list.first(spans)
  should.equal(
    check([Span(..first, wire_path: "/wrong"), ..list.drop(spans, 1)], False),
    Error(otlp_verify.WrongPath),
  )
  should.equal(
    check(
      [Span(..first, resource_service: "wrong"), ..list.drop(spans, 1)],
      False,
    ),
    Error(otlp_verify.WrongResource),
  )
  should.equal(
    check([Span(..first, scope_name: "wrong"), ..list.drop(spans, 1)], False),
    Error(otlp_verify.WrongScope),
  )
  let leaked =
    Span(..first, attributes: [
      #("nested", otlp_verify.Entries([#("safe", Text("Bearer hidden"))])),
    ])
  should.equal(
    check([leaked, ..list.drop(spans, 1)], False),
    Error(otlp_verify.PrivacyLeak),
  )
}

pub fn rejected_status_message_privacy_test() {
  let spans = fixture(False)
  let assert Ok(first) = list.first(spans)
  let leaked = Span(..first, status_message: "synthetic-account")
  should.equal(
    check([leaked, ..list.drop(spans, 1)], False),
    Error(otlp_verify.PrivacyLeak),
  )
}

pub fn topology_model_and_usage_changes_are_rejected_test() {
  let spans = fixture(False)
  let assert [server, logical, attempt, ..rest] = spans
  list.each(
    [
      Span(..logical, parent_span_id: "bbbbbbbbbbbbbbbb"),
      Span(
        ..logical,
        attributes: list.key_set(
          logical.attributes,
          "gen_ai.request.model",
          Text("wrong-model"),
        ),
      ),
      Span(
        ..logical,
        attributes: list.key_set(
          logical.attributes,
          "gen_ai.usage.input_tokens",
          Number(99),
        ),
      ),
      Span(
        ..logical,
        attributes: list.key_set(
          logical.attributes,
          "gen_ai.response.finish_reasons",
          Text("stop"),
        ),
      ),
      Span(..logical, end: 0),
      Span(..logical, status: "error"),
    ],
    fn(changed) {
      should.equal(
        check([server, changed, attempt, ..rest], False),
        Error(otlp_verify.WrongTopology("valid span groups")),
      )
    },
  )
}

pub fn capture_requires_valid_json_and_correct_marker_test() {
  let spans = fixture(True)
  let assert [server, logical, attempt, ..rest] = spans
  list.each(
    [
      Text("not-json codex-buffered-secret"),
      Text("[\"wrong-marker\"]"),
      Number(7),
    ],
    fn(value) {
      let changed =
        Span(
          ..logical,
          attributes: list.key_set(
            logical.attributes,
            "gen_ai.input.messages",
            value,
          ),
        )
      should.equal(
        check([server, changed, attempt, ..rest], True),
        Error(otlp_verify.WrongTopology("valid span groups")),
      )
    },
  )
  let escaped =
    Span(
      ..logical,
      attributes: list.key_set(
        logical.attributes,
        "gen_ai.input.messages",
        Text("[\"\\u0063odex-buffered-secret\"]"),
      ),
    )
  should.equal(check([server, escaped, attempt, ..rest], True), Ok(Nil))
}

pub fn rejects_content_on_server_and_rejected_spans_test() {
  let spans = fixture(True)
  let assert [server, ..rest] = spans
  let changed =
    Span(..server, attributes: [
      #("gen_ai.output.messages", Text("[]")),
      ..server.attributes
    ])
  should.equal(
    check([changed, ..rest], True),
    Error(otlp_verify.WrongTopology("valid span groups")),
  )
  let leaked =
    list.index_map(spans, fn(span, index) {
      case index == 12 {
        True ->
          Span(..span, attributes: [
            #("gen_ai.input.messages", Text("[]")),
            ..span.attributes
          ])
        False -> span
      }
    })
  should.equal(
    check(leaked, True),
    Error(otlp_verify.WrongTopology("rejected spans")),
  )
}

pub fn bytes_and_nested_arrays_cannot_hide_credentials_test() {
  let spans = fixture(False)
  let assert [first, ..rest] = spans
  list.each(
    [
      otlp_verify.Bytes(bit_array.from_string("synthetic-client-api-key")),
      Values([otlp_verify.Entries([#("nested", Text("Bearer hidden"))])]),
    ],
    fn(value) {
      let leaked =
        Span(..first, attributes: [#("private", value), ..first.attributes])
      should.equal(
        check([leaked, ..rest], False),
        Error(otlp_verify.PrivacyLeak),
      )
    },
  )
}

pub fn content_placement_and_marker_test() {
  let spans = fixture(False)
  let logical =
    list.index_map(spans, fn(span, i) {
      case i == 1 {
        True ->
          Span(..span, attributes: [
            #("gen_ai.input.messages", Text("leak")),
            ..span.attributes
          ])
        False -> span
      }
    })
  should.not_equal(check(logical, False), Ok(Nil))
}

fn fixture(capture: Bool) -> List(Span) {
  let traces = [
    #(
      "00000000000000000000000000000011",
      "/v1/responses",
      "responses",
      "openai",
      "fake-codex",
      "chatgpt",
      "responses-fixture",
      "codex-buffered-secret",
      "responses-output-marker",
    ),
    #(
      "00000000000000000000000000000012",
      "/v1/responses",
      "responses",
      "openai",
      "fake-codex",
      "chatgpt",
      "responses-fixture",
      "codex-stream-secret",
      "responses-output-marker",
    ),
    #(
      "00000000000000000000000000000021",
      "/v1/chat/completions",
      "chat_completions",
      "zai",
      "fake-zai",
      "zai",
      "chat-fixture",
      "zai-buffered-secret",
      "chat-output-marker",
    ),
    #(
      "00000000000000000000000000000022",
      "/v1/chat/completions",
      "chat_completions",
      "zai",
      "fake-zai",
      "zai",
      "chat-fixture",
      "zai-stream-secret",
      "chat-output-marker",
    ),
  ]
  let valid =
    list.flatten(
      list.map(traces, fn(row) {
        let #(
          trace,
          route,
          api,
          provider,
          model,
          target,
          response,
          input,
          output,
        ) = row
        let server_id = "aaaaaaaaaaaaaaaa"
        let logical_id = "2222222222222222"
        let attempt_id = "3333333333333333"
        let server =
          make(trace, server_id, "1111111111111111", "server", route, [
            #("pig.outcome", Text("succeeded")),
            #("http.route", Text(route)),
            #("http.response.status_code", Number(200)),
          ])
        let content = case capture {
          True -> [
            #("pig.content.input.status", Text("captured")),
            #("pig.content.output.status", Text("captured")),
            #("gen_ai.input.messages", Text("[\"" <> input <> "\"]")),
            #("gen_ai.output.messages", Text("[\"" <> output <> "\"]")),
          ]
          False -> []
        }
        let logical =
          make(trace, logical_id, server_id, "client", "chat", [
            #("pig.outcome", Text("succeeded")),
            #("gen_ai.operation.name", Text("chat")),
            #("openai.api.type", Text(api)),
            #("gen_ai.provider.name", Text(provider)),
            #("gen_ai.request.model", Text(model)),
            #("gen_ai.response.model", Text(model)),
            #("gen_ai.response.id", Text(response)),
            #("gen_ai.response.finish_reasons", Values([Text("stop")])),
            #("gen_ai.usage.input_tokens", Number(11)),
            #("gen_ai.usage.output_tokens", Number(7)),
            #("gen_ai.usage.cache_read.input_tokens", Number(3)),
            ..content
          ])
        let attempt =
          make(trace, attempt_id, logical_id, "client", "attempt", [
            #("pig.outcome", Text("succeeded")),
            #("pig.proxy.target.id", Text(target)),
            #("pig.proxy.attempt", Number(1)),
            #("http.response.status_code", Number(200)),
          ])
        [server, logical, attempt]
      }),
    )
  let rejected =
    list.map([0, 1, 2, 3, 4, 5, 6, 7], fn(i) {
      make(
        "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
        int_id(i),
        "1111111111111111",
        case i < 5 {
          True -> "server"
          False -> "client"
        },
        "rejected",
        [#("pig.outcome", Text("rejected"))],
      )
    })
  list.append(valid, rejected)
}

fn make(
  trace: String,
  id: String,
  parent: String,
  kind: String,
  name: String,
  attrs: List(#(String, otlp_verify.AttributeValue)),
) -> Span {
  Span(
    trace_id: trace,
    span_id: id,
    parent_span_id: parent,
    kind: kind,
    name: name,
    attributes: attrs,
    wire_path: "/v1/traces",
    start: 1,
    end: 2,
    status: "unset",
    status_message: "",
    events: 0,
    links: 0,
    resource_service: "pig-proxy-subscriptions",
    scope_name: "pig_proxy",
  )
}

fn int_id(i: Int) -> String {
  "eeeeeeeeeeeeeee" <> int.to_string(i)
}

fn check(
  spans: List(Span),
  capture: Bool,
) -> Result(Nil, otlp_verify.VerificationError) {
  otlp_verify.verify(spans, capture)
}
