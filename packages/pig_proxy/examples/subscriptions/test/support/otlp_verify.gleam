//// Pure verification contract for the subscription OTLP export.

import gleam/bit_array
import gleam/bool
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type AttributeValue {
  Text(String)
  Number(Int)
  Decimal(Float)
  Flag(Bool)
  Bytes(BitArray)
  Values(List(AttributeValue))
  Entries(List(#(String, AttributeValue)))
}

pub type Span {
  Span(
    trace_id: String,
    span_id: String,
    parent_span_id: String,
    kind: String,
    name: String,
    attributes: List(#(String, AttributeValue)),
    wire_path: String,
    start: Int,
    end: Int,
    status: String,
    status_message: String,
    events: Int,
    links: Int,
    resource_service: String,
    scope_name: String,
  )
}

pub type VerificationError {
  WrongCount(expected: Int, actual: Int)
  WrongPath
  WrongResource
  WrongScope
  DuplicateSpanIds
  InvalidSpan
  PrivacyLeak
  WrongTopology(String)
}

const secret_fragments = [
  "synthetic-latitude-key", "synthetic-project", "synthetic-zai-key",
  "synthetic-client-key", "synthetic-client-api-key", "synthetic-client-account",
  "synthetic-account", "synthetic-signature", "Bearer ", "authorization",
]

const trace_ids = [
  "00000000000000000000000000000011",
  "00000000000000000000000000000012",
  "00000000000000000000000000000021",
  "00000000000000000000000000000022",
]

pub fn verify(
  spans: List(Span),
  capture: Bool,
) -> Result(Nil, VerificationError) {
  use _ <- result.try(expect(
    list.length(spans) == 20,
    WrongCount(20, list.length(spans)),
  ))
  use _ <- result.try(expect(unique_ids(spans), DuplicateSpanIds))
  use _ <- result.try(expect(
    list.all(spans, fn(s) { s.wire_path == "/v1/traces" }),
    WrongPath,
  ))
  use _ <- result.try(expect(
    list.all(spans, fn(s) { s.resource_service == "pig-proxy-subscriptions" }),
    WrongResource,
  ))
  use _ <- result.try(expect(
    list.all(spans, fn(s) { s.scope_name == "pig_proxy" }),
    WrongScope,
  ))
  use _ <- result.try(case list.find(spans, leaks) {
    Ok(_) -> Error(PrivacyLeak)
    Error(Nil) -> Ok(Nil)
  })
  use _ <- result.try(
    case list.find(spans, fn(s) { s.events != 0 || s.links != 0 }) {
      Ok(_) -> Error(InvalidSpan)
      Error(Nil) -> Ok(Nil)
    },
  )
  use _ <- result.try(expect(
    rejected_spans_valid(spans),
    WrongTopology("rejected spans"),
  ))
  use _ <- result.try(expect(
    valid_groups(spans, capture),
    WrongTopology("valid span groups"),
  ))
  Ok(Nil)
}

fn expect(
  ok: Bool,
  error: VerificationError,
) -> Result(Nil, VerificationError) {
  case ok {
    True -> Ok(Nil)
    False -> Error(error)
  }
}

fn unique_ids(spans: List(Span)) -> Bool {
  let ids = list.map(spans, fn(s) { #(s.trace_id, s.span_id) })
  list.length(list.unique(ids)) == list.length(spans)
}

fn leaks(span: Span) -> Bool {
  string_contains_any(span.name, secret_fragments)
  || string_contains_any(span.status, secret_fragments)
  || string_contains_any(span.status_message, secret_fragments)
  || string_contains_any(span.resource_service, secret_fragments)
  || string_contains_any(span.scope_name, secret_fragments)
  || list.any(span.attributes, fn(pair) {
    let #(key, value) = pair
    string_contains_any(key, secret_fragments) || value_leaks(value)
  })
}

fn value_leaks(value: AttributeValue) -> Bool {
  case value {
    Text(text) -> string_contains_any(text, secret_fragments)
    Number(_) -> False
    Decimal(_) -> False
    Flag(_) -> False
    Bytes(bytes) -> {
      case bit_array.to_string(bytes) {
        Ok(text) -> string_contains_any(text, secret_fragments)
        Error(_) -> False
      }
    }
    Values(values) -> list.any(values, value_leaks)
    Entries(entries) ->
      list.any(entries, fn(pair) {
        let #(key, nested) = pair
        string_contains_any(key, secret_fragments) || value_leaks(nested)
      })
  }
}

fn string_contains_any(value: String, fragments: List(String)) -> Bool {
  list.any(fragments, fn(fragment) { string.contains(value, fragment) })
}

fn rejected_spans_valid(spans: List(Span)) -> Bool {
  let rejected =
    list.filter(spans, fn(s) { !list.contains(trace_ids, s.trace_id) })
  list.length(rejected) == 8
  && list.length(list.filter(rejected, fn(s) { s.kind == "server" })) == 5
  && list.length(list.filter(rejected, fn(s) { s.kind == "client" })) == 3
  && list.all(rejected, fn(s) { !has_content_key(s) })
}

fn valid_groups(spans: List(Span), capture: Bool) -> Bool {
  list.length(
    list.filter(spans, fn(s) { list.contains(trace_ids, s.trace_id) }),
  )
  == 12
  && list.all(trace_ids, fn(trace) { valid_group(trace, spans, capture) })
}

fn valid_group(trace: String, spans: List(Span), capture: Bool) -> Bool {
  let group = list.filter(spans, fn(s) { s.trace_id == trace })
  case group {
    [a, b, c] -> verify_group(trace, [a, b, c], capture)
    _ -> False
  }
}

fn verify_group(trace: String, group: List(Span), capture: Bool) -> Bool {
  let servers = list.filter(group, fn(s) { s.kind == "server" })
  let logicals =
    list.filter(group, fn(s) { attr_text(s, "gen_ai.operation.name") == "chat" })
  let attempts =
    list.filter(group, fn(s) { has_attr(s, "pig.proxy.target.id") })
  case servers, logicals, attempts {
    [server], [logical], [attempt] -> {
      let route = attr_text(server, "http.route")
      let mapping = trace_mapping(trace)
      case mapping {
        Error(Nil) -> False
        Ok(#(
          expected_route,
          stream,
          input,
          api,
          provider,
          model,
          target,
          response,
          output,
        )) ->
          route == expected_route
          && server.parent_span_id == "1111111111111111"
          && logical.parent_span_id == server.span_id
          && attempt.parent_span_id == logical.span_id
          && logical.kind == "client"
          && attempt.kind == "client"
          && attr_text(logical, "openai.api.type") == api
          && attr_text(logical, "gen_ai.provider.name") == provider
          && attr_text(logical, "gen_ai.request.model") == model
          && attr_text(logical, "gen_ai.response.model") == model
          && attr_text(logical, "gen_ai.response.id") == response
          && attr(logical, "gen_ai.response.finish_reasons")
          == Ok(Values([Text("stop")]))
          && attr_int(logical, "gen_ai.usage.input_tokens") == 11
          && attr_int(logical, "gen_ai.usage.output_tokens") == 7
          && attr_int(logical, "gen_ai.usage.cache_read.input_tokens") == 3
          && attr_text(attempt, "pig.proxy.target.id") == target
          && attr_int(attempt, "pig.proxy.attempt") == 1
          && common_group_checks(group)
          && attr_int(server, "http.response.status_code") == 200
          && attr_int(attempt, "http.response.status_code") == 200
          && content_valid(group, logical, capture, input, output, stream)
      }
    }
    _, _, _ -> False
  }
}

fn trace_mapping(
  trace: String,
) -> Result(
  #(String, Bool, String, String, String, String, String, String, String),
  Nil,
) {
  case trace {
    "00000000000000000000000000000011" ->
      Ok(#(
        "/v1/responses",
        False,
        "codex-buffered-secret",
        "responses",
        "openai",
        "fake-codex",
        "chatgpt",
        "responses-fixture",
        "responses-output-marker",
      ))
    "00000000000000000000000000000012" ->
      Ok(#(
        "/v1/responses",
        True,
        "codex-stream-secret",
        "responses",
        "openai",
        "fake-codex",
        "chatgpt",
        "responses-fixture",
        "responses-output-marker",
      ))
    "00000000000000000000000000000021" ->
      Ok(#(
        "/v1/chat/completions",
        False,
        "zai-buffered-secret",
        "chat_completions",
        "zai",
        "fake-zai",
        "zai",
        "chat-fixture",
        "chat-output-marker",
      ))
    "00000000000000000000000000000022" ->
      Ok(#(
        "/v1/chat/completions",
        True,
        "zai-stream-secret",
        "chat_completions",
        "zai",
        "fake-zai",
        "zai",
        "chat-fixture",
        "chat-output-marker",
      ))
    _ -> Error(Nil)
  }
}

fn common_group_checks(group: List(Span)) -> Bool {
  list.all(group, fn(s) {
    s.start > 0
    && s.end >= s.start
    && s.status == "unset"
    && attr_text(s, "pig.outcome") == "succeeded"
  })
}

fn content_valid(
  group: List(Span),
  logical: Span,
  capture: Bool,
  input: String,
  output: String,
  _stream: Bool,
) -> Bool {
  let others_clean =
    list.all(group, fn(s) {
      s.span_id == logical.span_id || !has_content_key(s)
    })
  case others_clean, capture {
    False, _ -> False
    True, True ->
      attr_text(logical, "pig.content.input.status") == "captured"
      && attr_text(logical, "pig.content.output.status") == "captured"
      && json_contains(logical, "gen_ai.input.messages", input)
      && json_contains(logical, "gen_ai.output.messages", output)
    True, False ->
      list.all(group, fn(s) { !has_content_key(s) })
      && !string.contains(all_group_text(group), input)
      && !string.contains(all_group_text(group), output)
  }
}

fn has_content_key(span: Span) -> Bool {
  list.any(span.attributes, fn(pair) {
    let #(key, _) = pair
    string.starts_with(key, "gen_ai.input.")
    || string.starts_with(key, "gen_ai.output.")
    || key == "gen_ai.system_instructions"
    || key == "gen_ai.tool.definitions"
  })
}

fn json_contains(span: Span, key: String, marker: String) -> Bool {
  case attr(span, key) {
    Ok(Text(encoded)) -> {
      case json.parse(encoded, decode.dynamic) {
        Ok(value) -> json_value_contains(value, marker)
        Error(_) -> False
      }
    }
    _ -> False
  }
}

fn json_value_contains(value: Dynamic, marker: String) -> Bool {
  case decode.run(value, decode.string) {
    Ok(text) -> string.contains(text, marker)
    Error(_) -> {
      case decode.run(value, decode.list(decode.dynamic)) {
        Ok(values) ->
          list.any(values, fn(value) { json_value_contains(value, marker) })
        Error(_) -> {
          case decode.run(value, decode.dict(decode.string, decode.dynamic)) {
            Ok(entries) -> {
              entries
              |> dict.to_list
              |> list.any(fn(entry) {
                string.contains(entry.0, marker)
                || json_value_contains(entry.1, marker)
              })
            }
            Error(_) -> False
          }
        }
      }
    }
  }
}

fn all_group_text(group: List(Span)) -> String {
  list.fold(group, "", fn(acc, span) {
    list.fold(span.attributes, acc, fn(inner, pair) {
      let #(key, value) = pair
      inner <> key <> value_as_text(value)
    })
  })
}

fn value_as_text(value: AttributeValue) -> String {
  case value {
    Text(text) -> text
    Number(number) -> int.to_string(number)
    Decimal(value) -> float.to_string(value)
    Flag(flag) -> bool.to_string(flag)
    Bytes(bytes) -> {
      case bit_array.to_string(bytes) {
        Ok(text) -> text
        Error(_) -> ""
      }
    }
    Values(values) ->
      list.fold(values, "", fn(acc, nested) { acc <> value_as_text(nested) })
    Entries(entries) ->
      list.fold(entries, "", fn(acc, pair) {
        let #(key, nested) = pair
        acc <> key <> value_as_text(nested)
      })
  }
}

fn attr(span: Span, key: String) -> Result(AttributeValue, Nil) {
  case list.find(span.attributes, fn(pair) { pair.0 == key }) {
    Ok(pair) -> Ok(pair.1)
    Error(Nil) -> Error(Nil)
  }
}

fn has_attr(span: Span, key: String) -> Bool {
  result.is_ok(attr(span, key))
}

fn attr_text(span: Span, key: String) -> String {
  case attr(span, key) {
    Ok(Text(value)) -> value
    _ -> ""
  }
}

fn attr_int(span: Span, key: String) -> Int {
  case attr(span, key) {
    Ok(Number(value)) -> value
    _ -> -1
  }
}
