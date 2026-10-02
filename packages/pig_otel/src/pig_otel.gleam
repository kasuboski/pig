//// Metadata-only tracing for Pig. The host owns the SDK and propagators.
//// Contexts and spans are VM-local handles, never durable protocol values.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import logging
import otel/attribute.{type Attribute}
import otel/context.{type Context}
import otel/propagation
import otel/trace
import pig_otel/content/options
import pig_protocol/inference.{type InferenceMetadata}
import pig_protocol/stop_reason

/// Shared span, metadata-only, and explicitly bounded conversation-capture policies.
pub type Policy {
  MetadataOnly
  Conversation(options.Options)
  Disabled
}

/// An operation-local tracer, resolved after the consumer application is loaded.
pub opaque type Backend {
  Enabled(trace.Tracer)
  NoTracing
}

/// A live explicit span or the unchanged explicit parent when disabled.
/// Its lifecycle owner must arbitrate terminal outcomes before calling finish.
pub opaque type Span {
  Owned(trace.Span)
  ParentOnly(Context)
}

/// Known API flavor, independent of the provider's service identity.
pub type Api {
  ChatCompletions
  Responses
  Custom
}

/// Known metadata only. Names must be configured identities, not request content.
pub type Operation {
  Run(agent_name: Option(String), run_id: String)
  Inference(api: Api, provider_name: Option(String), model: Option(String))
  Tool(name: String, call_id: String)
  HttpServer(route: String)
  HttpAttempt(target_id: String)
}

/// Terminal facts. Categories are normalized to a finite allowlist.
pub type Outcome {
  Succeeded
  Failed(category: String)
  Cancelled(category: String)
}

/// Resolve the marker's defining application, never a default/shared scope.
/// Disabled does not perform lookup. Lookup failure logs a fixed diagnostic and
/// disables instrumentation without changing business work or propagation.
pub fn backend(policy: Policy, marker: fn() -> Nil) -> Backend {
  case policy {
    Disabled -> NoTracing
    MetadataOnly | Conversation(_) ->
      case trace.tracer_for(marker) {
        Ok(tracer) -> Enabled(tracer)
        Error(trace.MarkerApplicationNotFound) -> {
          logging.log(
            logging.Warning,
            "Pig tracing disabled: marker application not found",
          )
          NoTracing
        }
      }
  }
}

/// Disable spans without disabling sanitized explicit-parent propagation.
pub fn disabled() -> Backend {
  NoTracing
}

/// Whether tracer acquisition succeeded for this operation. An enabled no-op
/// tracer is available; this does not reveal SDK recording or sampling state.
pub fn tracing_available(backend: Backend) -> Bool {
  case backend {
    Enabled(_) -> True
    NoTracing -> False
  }
}

/// Start without installing process-current context. The caller owns completion.
pub fn start(backend: Backend, parent: Context, operation: Operation) -> Span {
  case backend {
    NoTracing -> ParentOnly(parent)
    Enabled(tracer) -> {
      let #(name, kind, attributes) = describe(operation)
      let assert Ok(name) = trace.span_name(name)
      let options = trace.options(kind) |> trace.attributes(attributes)
      Owned(trace.start(tracer, name, trace.Explicit(parent), options))
    }
  }
}

/// Explicit context for worker handoff, scoped callbacks, or propagation.
pub fn context(span: Span) -> Context {
  case span {
    ParentOnly(parent) -> parent
    Owned(span) -> trace.context(span)
  }
}

/// Add owned attributes while live. This adapter does not encode or sanitize
/// content: optional conversation attributes must come from an explicitly enabled,
/// bounded projection/redaction boundary. Never supply raw bodies or exceptions.
pub fn annotate(span: Span, attributes: List(Attribute)) -> Nil {
  case span {
    ParentOnly(_) -> Nil
    Owned(span) -> trace.set_attributes(span, attributes)
  }
}

/// Set bounded terminal metadata/status before ending. Repeated calls after end
/// are harmless. Terminal arbitration remains the consumer lifecycle owner's job.
pub fn finish(span: Span, outcome: Outcome) -> Nil {
  case span {
    ParentOnly(_) -> Nil
    Owned(span) -> {
      let #(status, attributes) = terminal(outcome)
      trace.set_attributes(span, attributes)
      trace.set_status(span, status)
      trace.end(span)
    }
  }
}

/// Pure names, kinds, and initial metadata from the pinned GenAI conventions.
/// No API flavor implies OpenAI service identity. No schema URL is invented.
pub fn describe(
  operation: Operation,
) -> #(String, trace.SpanKind, List(Attribute)) {
  case operation {
    Run(agent_name, run_id) -> #(
      named("invoke_agent", agent_name),
      trace.Internal,
      list.append(
        [
          string_attribute("gen_ai.operation.name", "invoke_agent"),
          string_attribute("pig.run.id", run_id),
        ],
        optional_string("gen_ai.agent.name", agent_name),
      ),
    )
    Inference(api, provider_name, model) -> #(
      named("chat", model),
      trace.Client,
      list.flatten([
        [string_attribute("gen_ai.operation.name", "chat")],
        optional_string("gen_ai.provider.name", provider_name),
        optional_string("gen_ai.request.model", model),
        api_attributes(api),
      ]),
    )
    Tool(name, call_id) -> #(named("execute_tool", Some(name)), trace.Internal, [
      string_attribute("gen_ai.operation.name", "execute_tool"),
      string_attribute("gen_ai.tool.name", name),
      string_attribute("gen_ai.tool.call.id", call_id),
    ])
    HttpServer(route) -> #(named("POST", Some(route)), trace.Server, [
      string_attribute("http.request.method", "POST"),
      string_attribute("http.route", route),
    ])
    HttpAttempt(target_id) -> #("POST", trace.Client, [
      string_attribute("http.request.method", "POST"),
      string_attribute("pig.proxy.target.id", target_id),
    ])
  }
}

fn named(operation: String, name: Option(String)) -> String {
  case name {
    None | Some("") -> operation
    Some(name) -> operation <> " " <> name
  }
}

fn api_attributes(api: Api) -> List(Attribute) {
  case api {
    ChatCompletions -> [string_attribute("openai.api.type", "chat_completions")]
    Responses -> [string_attribute("openai.api.type", "responses")]
    Custom -> []
  }
}

/// Pure terminal mapping. Success leaves status unset; failure and cancellation
/// set Error without an exception description. Unknown categories become _OTHER.
pub fn terminal(outcome: Outcome) -> #(trace.Status, List(Attribute)) {
  case outcome {
    Succeeded -> #(trace.StatusUnset, [
      string_attribute("pig.outcome", "succeeded"),
    ])
    Failed(category) -> #(trace.StatusError(None), [
      string_attribute("pig.outcome", "failed"),
      string_attribute("error.type", error_category(category)),
    ])
    Cancelled(category) -> #(trace.StatusError(None), [
      string_attribute("pig.outcome", "cancelled"),
      string_attribute("error.type", error_category(category)),
    ])
  }
}

fn error_category(category: String) -> String {
  case category {
    "timeout"
    | "deadline_exceeded"
    | "client_disconnected"
    | "agent_stopped"
    | "cancelled"
    | "rate_limited"
    | "authentication"
    | "invalid_request"
    | "provider_error"
    | "transport_error"
    | "tool_error"
    | "tool_blocked"
    | "tool_not_found"
    | "invalid_arguments"
    | "persistence_error"
    | "callback_error"
    | "process_exit"
    | "http_error"
    | "upstream_error"
    | "downstream_error" -> category
    _ -> "_OTHER"
  }
}

/// Map available response metadata; missing values stay absent, not zero.
/// Cached tokens are a subset of input tokens, never added to the total.
pub fn response_attributes(metadata: InferenceMetadata) -> List(Attribute) {
  list.flatten([
    optional_string("gen_ai.response.id", metadata.response_id),
    optional_string("gen_ai.response.model", metadata.response_model),
    case metadata.stop_reason {
      None -> []
      Some(reason) -> {
        let value = case reason {
          stop_reason.Unknown(_) -> "unknown"
          reason -> stop_reason.to_string(reason)
        }
        let assert Ok(key) = attribute.key("gen_ai.response.finish_reasons")
        [attribute.strings(key, [value])]
      }
    },
    optional_count("gen_ai.usage.input_tokens", metadata.input_tokens),
    optional_count("gen_ai.usage.output_tokens", metadata.output_tokens),
    optional_count(
      "gen_ai.usage.cache_read.input_tokens",
      metadata.cached_input_tokens,
    ),
  ])
}

fn optional_string(key: String, value: Option(String)) -> List(Attribute) {
  case value {
    None -> []
    Some(value) -> [string_attribute(key, value)]
  }
}

fn optional_count(key: String, value: Option(Int)) -> List(Attribute) {
  case value {
    Some(value) if value >= 0 -> [int_attribute(key, value)]
    _ -> []
  }
}

/// Construct a known metadata attribute. The key must not be empty.
pub fn string_attribute(key: String, value: String) -> Attribute {
  let assert Ok(key) = attribute.key(key)
  attribute.string(key, value)
}

/// Construct a known integer metadata attribute. The key must not be empty.
pub fn int_attribute(key: String, value: Int) -> Attribute {
  let assert Ok(key) = attribute.key(key)
  attribute.int(key, value)
}

/// Construct a known boolean metadata attribute. The key must not be empty.
pub fn bool_attribute(key: String, value: Bool) -> Attribute {
  let assert Ok(key) = attribute.key(key)
  attribute.bool(key, value)
}

/// Extract detached context through the host's official composite propagator.
/// Strip all baggage before extraction, including malformed mixed-case entries.
pub fn ingress(headers: List(#(String, String))) -> Context {
  propagation.extract(drop_baggage(headers))
}

/// Replace stale propagation with the explicit parent's official propagation.
/// Also strips baggage recreated by injection from an ambient/caller context.
pub fn outbound(
  parent: Context,
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  headers
  |> scrub_propagation
  |> propagation.inject(parent, _)
  |> drop_baggage
}

/// Remove every propagation header occurrence; preserve unrelated headers/order.
/// Credential and hop-by-hop protection remains the HTTP caller's responsibility.
pub fn scrub_propagation(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  list.filter(headers, fn(header) {
    case string.lowercase(header.0) {
      "traceparent" | "tracestate" | "baggage" -> False
      _ -> True
    }
  })
}

/// Remove every case-insensitive baggage occurrence without parsing its contents.
pub fn drop_baggage(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  list.filter(headers, fn(header) { string.lowercase(header.0) != "baggage" })
}
