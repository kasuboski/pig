//// Typed projection of actual gpb OTLP terms; only protobuf decoding is foreign.

import exception
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode as dynamic_decode
import gleam/erlang/atom
import gleam/list
import gleam/string
import support/otlp_verify.{type AttributeValue, type Span}

@external(erlang, "opentelemetry_exporter_trace_service_pb", "decode_msg")
fn decode_msg(body: BitArray, message_type: atom.Atom) -> Dynamic

/// Decode an actual export body without leaking foreign decoder errors.
pub fn decode(body: BitArray, wire_path: String) -> Result(List(Span), Nil) {
  case
    exception.rescue(fn() {
      let request =
        decode_msg(body, atom.create("export_trace_service_request"))
      dynamic_decode.run(request, export_decoder(wire_path))
    })
  {
    Ok(Ok(spans)) -> Ok(spans)
    _ -> Error(Nil)
  }
}

fn export_decoder(path: String) -> dynamic_decode.Decoder(List(Span)) {
  use resources <- dynamic_decode.field(
    atom.create("resource_spans"),
    dynamic_decode.list(resource_decoder(path)),
  )
  dynamic_decode.success(list.flatten(resources))
}

fn resource_decoder(path: String) -> dynamic_decode.Decoder(List(Span)) {
  let resource_attributes = {
    use attrs <- dynamic_decode.optional_field(
      atom.create("attributes"),
      [],
      dynamic_decode.list(attribute()),
    )
    dynamic_decode.success(attrs)
  }
  use attrs <- dynamic_decode.field(
    atom.create("resource"),
    resource_attributes,
  )
  let service = case list.find(attrs, fn(pair) { pair.0 == "service.name" }) {
    Ok(#(_, otlp_verify.Text(name))) -> name
    _ -> ""
  }
  use scopes <- dynamic_decode.field(
    atom.create("scope_spans"),
    dynamic_decode.list(scope_decoder(path, service)),
  )
  dynamic_decode.success(list.flatten(scopes))
}

fn scope_decoder(
  path: String,
  service: String,
) -> dynamic_decode.Decoder(List(Span)) {
  let scope_name = {
    use name <- dynamic_decode.field(atom.create("name"), dynamic_decode.string)
    dynamic_decode.success(name)
  }
  use name <- dynamic_decode.field(atom.create("scope"), scope_name)
  use spans <- dynamic_decode.field(
    atom.create("spans"),
    dynamic_decode.list(span_decoder(path, service, name)),
  )
  dynamic_decode.success(spans)
}

fn span_decoder(
  path: String,
  service: String,
  scope: String,
) -> dynamic_decode.Decoder(Span) {
  use trace <- dynamic_decode.field(
    atom.create("trace_id"),
    dynamic_decode.bit_array,
  )
  use span_id <- dynamic_decode.field(
    atom.create("span_id"),
    dynamic_decode.bit_array,
  )
  use parent <- dynamic_decode.optional_field(
    atom.create("parent_span_id"),
    <<>>,
    dynamic_decode.bit_array,
  )
  use kind <- dynamic_decode.field(atom.create("kind"), atom.decoder())
  use name <- dynamic_decode.field(atom.create("name"), dynamic_decode.string)
  use attrs <- dynamic_decode.optional_field(
    atom.create("attributes"),
    [],
    dynamic_decode.list(attribute()),
  )
  use start <- dynamic_decode.field(
    atom.create("start_time_unix_nano"),
    dynamic_decode.int,
  )
  use end <- dynamic_decode.field(
    atom.create("end_time_unix_nano"),
    dynamic_decode.int,
  )
  use status <- dynamic_decode.optional_field(
    atom.create("status"),
    #("unset", ""),
    status_decoder(),
  )
  use events <- dynamic_decode.optional_field(
    atom.create("events"),
    [],
    dynamic_decode.list(dynamic_decode.dynamic),
  )
  use links <- dynamic_decode.optional_field(
    atom.create("links"),
    [],
    dynamic_decode.list(dynamic_decode.dynamic),
  )
  dynamic_decode.success(otlp_verify.Span(
    trace_id: string.lowercase(bit_array.base16_encode(trace)),
    span_id: string.lowercase(bit_array.base16_encode(span_id)),
    parent_span_id: string.lowercase(bit_array.base16_encode(parent)),
    kind: span_kind(atom.to_string(kind)),
    name: name,
    attributes: attrs,
    wire_path: path,
    start: start,
    end: end,
    status: status.0,
    status_message: status.1,
    events: list.length(events),
    links: list.length(links),
    resource_service: service,
    scope_name: scope,
  ))
}

fn status_decoder() -> dynamic_decode.Decoder(#(String, String)) {
  use code <- dynamic_decode.optional_field(
    atom.create("code"),
    atom.create("STATUS_CODE_UNSET"),
    atom.decoder(),
  )
  use message <- dynamic_decode.optional_field(
    atom.create("message"),
    "",
    dynamic_decode.string,
  )
  dynamic_decode.success(#(status_code(atom.to_string(code)), message))
}

fn span_kind(kind: String) -> String {
  case kind {
    "SPAN_KIND_SERVER" -> "server"
    "SPAN_KIND_CLIENT" -> "client"
    _ -> kind
  }
}

fn status_code(code: String) -> String {
  case code {
    "STATUS_CODE_UNSET" -> "unset"
    "STATUS_CODE_OK" -> "ok"
    "STATUS_CODE_ERROR" -> "error"
    _ -> code
  }
}

fn attribute() -> dynamic_decode.Decoder(#(String, AttributeValue)) {
  use key <- dynamic_decode.field(atom.create("key"), dynamic_decode.string)
  use value <- dynamic_decode.field(atom.create("value"), any_value())
  dynamic_decode.success(#(key, value))
}

fn tagged_value() -> dynamic_decode.Decoder(#(String, Dynamic)) {
  use tag <- dynamic_decode.field(0, atom.decoder())
  use value <- dynamic_decode.field(1, dynamic_decode.dynamic)
  dynamic_decode.success(#(atom.to_string(tag), value))
}

fn any_value() -> dynamic_decode.Decoder(AttributeValue) {
  use tagged <- dynamic_decode.field(atom.create("value"), tagged_value())
  let #(kind, payload) = tagged
  let decoder = case kind {
    "string_value" ->
      dynamic_decode.map(dynamic_decode.string, otlp_verify.Text)
    "int_value" -> dynamic_decode.map(dynamic_decode.int, otlp_verify.Number)
    "double_value" ->
      dynamic_decode.map(dynamic_decode.float, otlp_verify.Decimal)
    "bool_value" -> dynamic_decode.map(dynamic_decode.bool, otlp_verify.Flag)
    "bytes_value" ->
      dynamic_decode.map(dynamic_decode.bit_array, otlp_verify.Bytes)
    "array_value" -> {
      use values <- dynamic_decode.optional_field(
        atom.create("values"),
        [],
        dynamic_decode.list(any_value()),
      )
      dynamic_decode.success(otlp_verify.Values(values))
    }
    "kvlist_value" -> {
      use values <- dynamic_decode.optional_field(
        atom.create("values"),
        [],
        dynamic_decode.list(attribute()),
      )
      dynamic_decode.success(otlp_verify.Entries(values))
    }
    _ -> dynamic_decode.failure(otlp_verify.Text(""), "OTLP AnyValue")
  }
  case dynamic_decode.run(payload, decoder) {
    Ok(value) -> dynamic_decode.success(value)
    Error(_) -> dynamic_decode.failure(otlp_verify.Text(""), "OTLP AnyValue")
  }
}
