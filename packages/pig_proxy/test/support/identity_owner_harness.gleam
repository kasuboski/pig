//// Runtime proxy owner identity checks using the SDK recording fixture.

import gleam/list
import gleam/option.{None}
import gleeunit/should
import otel/attribute
import pig_otel
import pig_otel/identity
import pig_otel/proxy_ingress
import pig_proxy/trace_metadata
import pig_proxy/tracing
import support/tracing_harness as tracing_check

@external(erlang, "pig_proxy_identity_owner_test_ffi", "with_upstream_propagator")
pub fn with_upstream_propagator(work: fn() -> a) -> a

/// Register two owners through the real ingress extraction boundary, then
/// interleave their lifecycle commands and verify exact span-local identity.
pub fn check_interleaved_owners() -> Nil {
  use recorder <- tracing_check.with_calls
  use <- with_upstream_propagator
  assert_extraction("session-probe", "conversation-probe")
  let owners = tracing_check.owners()
  let owner_a = register(owners, "session-a", "conversation-a")
  let owner_b = register(owners, "session-b", "conversation-b")

  begin(owner_a)
  begin(owner_b)
  attempts(owner_a)
  attempts(owner_b)

  let metadata =
    trace_metadata.buffered(
      pig_otel.ChatCompletions,
      "{\"choices\":[{\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":17,\"completion_tokens\":5}}",
    )
  let _ =
    tracing.call(
      owner_a,
      tracing.LogicalTerminal(pig_otel.Failed("upstream_error"), metadata, 502),
    )
  let _ =
    tracing.call(
      owner_b,
      tracing.LogicalTerminal(pig_otel.Succeeded, metadata, 200),
    )
  let _ =
    tracing.call(owner_a, tracing.Downstream(pig_otel.Failed("upstream_error")))
  let _ =
    tracing.call(
      owner_b,
      tracing.Downstream(pig_otel.Cancelled("client_cancelled")),
    )
  tracing_check.wait_closed(owner_a, fn() { Nil })
  tracing_check.wait_closed(owner_b, fn() { Nil })

  let events = tracing_check.calls(recorder)
  assert_identity(events, "session-a", "conversation-a", 2)
  assert_identity(events, "session-b", "conversation-b", 2)
  assert_metadata_count(events, 2)
}

/// Shutdown is a separate terminal path and must retire the registered owner.
pub fn check_shutdown_owner() -> Nil {
  use recorder <- tracing_check.with_calls
  use <- with_upstream_propagator
  assert_extraction("session-shutdown", "conversation-shutdown")
  let owner =
    register(
      tracing_check.owners(),
      "session-shutdown",
      "conversation-shutdown",
    )
  begin(owner)
  let _ = tracing.call(owner, tracing.Shutdown)
  tracing_check.wait_closed(owner, fn() { Nil })
  assert_identity(
    tracing_check.calls(recorder),
    "session-shutdown",
    "conversation-shutdown",
    0,
  )
}

fn assert_extraction(session: String, conversation: String) -> Nil {
  let #(_, extracted) =
    proxy_ingress.extract([
      #(
        "baggage",
        "session.id=" <> session <> ",gen_ai.conversation.id=" <> conversation,
      ),
    ])
  should.equal(
    identity.attributes(identity.for_span(extracted, identity.LogicalInference)),
    [
      pig_otel.string_attribute("session.id", session),
      pig_otel.string_attribute("gen_ai.conversation.id", conversation),
    ],
  )
}

fn register(
  owners: tracing.Owners,
  session: String,
  conversation: String,
) -> tracing.Owner {
  tracing.register(
    owners,
    pig_otel.MetadataOnly,
    [
      #(
        "baggage",
        "session.id=" <> session <> ",gen_ai.conversation.id=" <> conversation,
      ),
    ],
    "/v1/chat/completions",
  )
}

fn begin(owner: tracing.Owner) -> Nil {
  let _ =
    tracing.call(
      owner,
      tracing.BeginInference(
        pig_otel.ChatCompletions,
        None,
        "fixture-model",
        None,
      ),
    )
  Nil
}

fn attempts(owner: tracing.Owner) -> Nil {
  let _ = tracing.call(owner, tracing.BeginAttempt("fallback-one"))
  let _ = tracing.call(owner, tracing.AbortAttempt)
  let _ = tracing.call(owner, tracing.BeginAttempt("fallback-two"))
  let _ = tracing.call(owner, tracing.AbortAttempt)
  Nil
}

fn assert_identity(
  events: List(tracing_check.Call),
  session: String,
  conversation: String,
  expected_attempts: Int,
) -> Nil {
  let server = pig_otel.string_attribute("session.id", session)
  let conversation_attr =
    pig_otel.string_attribute("gen_ai.conversation.id", conversation)
  let relevant =
    list.filter_map(events, fn(event) {
      case event {
        tracing_check.StartedWithAttributes(span, _, operation, _) -> {
          let is_server_or_logical = case operation {
            pig_otel.HttpServer(_) | pig_otel.Inference(_, _, _) -> True
            _ -> False
          }
          let is_logical = case operation {
            pig_otel.Inference(_, _, _) -> True
            _ -> False
          }
          let is_attempt = case operation {
            pig_otel.HttpAttempt(_) -> True
            _ -> False
          }
          let carries_session =
            list.contains(
              attributes_for(events, span),
              pig_otel.string_attribute("session.id", session),
            )
          case is_server_or_logical || is_attempt {
            True if carries_session -> Ok(#(span, is_logical, is_attempt))
            _ -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }
    })
  should.equal(list.length(relevant), 2 + expected_attempts)
  list.each(relevant, fn(entry) {
    let attrs = attributes_for(events, entry.0)
    should.be_true(list.contains(attrs, server))
    case entry.1 {
      True -> should.be_true(list.contains(attrs, conversation_attr))
      False -> should.be_false(list.contains(attrs, conversation_attr))
    }
    case entry.2 {
      True -> should.be_false(list.contains(attrs, conversation_attr))
      False -> Nil
    }
  })
}

fn assert_metadata_count(
  events: List(tracing_check.Call),
  expected: Int,
) -> Nil {
  let logical_spans =
    list.filter_map(events, fn(event) {
      case event {
        tracing_check.Started(span, _, pig_otel.Inference(_, _, _)) -> Ok(span)
        _ -> Error(Nil)
      }
    })
  should.equal(list.length(logical_spans), expected)
  list.each(logical_spans, fn(span) {
    let attrs = attributes_for(events, span)
    should.be_true(list.contains(
      attrs,
      pig_otel.int_attribute("gen_ai.usage.input_tokens", 17),
    ))
    should.be_true(list.contains(
      attrs,
      pig_otel.int_attribute("gen_ai.usage.output_tokens", 5),
    ))
  })
}

fn attributes_for(
  events: List(tracing_check.Call),
  span: pig_otel.Span,
) -> List(attribute.Attribute) {
  list.flatten(
    list.filter_map(events, fn(event) {
      case event {
        tracing_check.Annotated(event_span, attrs) if event_span == span ->
          Ok(attrs)
        tracing_check.StartedWithAttributes(event_span, _, _, attrs)
          if event_span == span
        -> Ok(attrs)
        _ -> Error(Nil)
      }
    }),
  )
}
