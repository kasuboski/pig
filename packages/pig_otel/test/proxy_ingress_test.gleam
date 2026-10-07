//// Proxy-specific baggage extraction boundary tests.

import gleam/option.{None, Some}
import gleeunit/should
import otel/context
import pig_otel
import pig_otel/identity
import pig_otel/proxy_ingress
import support/harness

pub fn proxy_ingress_extracts_validated_identity_and_clears_baggage_test() {
  harness.with_composite(fn() {
    let #(parent, extracted) =
      proxy_ingress.extract([
        #(
          "baggage",
          "session.id=session-1,gen_ai.conversation.id=conversation-1,private=secret",
        ),
      ])
    should.equal(has_baggage(parent), False)
    should.equal(
      identity.for_span(extracted, identity.LogicalInference),
      identity.Enrichment(
        Some(must_identifier("session-1")),
        Some(must_identifier("conversation-1")),
      ),
    )
  })
}

pub fn proxy_ingress_keeps_valid_trace_when_identity_is_invalid_or_missing_test() {
  harness.with_composite(fn() {
    let #(parent, extracted) =
      proxy_ingress.extract([
        #("traceparent", harness.parent_header),
        #("baggage", "session.id=bad%0Avalue,gen_ai.conversation.id=ok"),
      ])
    should.equal(pig_otel.outbound(parent, []), [
      #("traceparent", harness.parent_header),
    ])
    should.equal(
      identity.for_span(extracted, identity.LogicalInference),
      identity.Enrichment(None, Some(must_identifier("ok"))),
    )

    let #(invalid_parent, no_identity) =
      proxy_ingress.extract([#("traceparent", "malformed")])
    should.equal(pig_otel.outbound(invalid_parent, []), [])
    should.equal(
      identity.for_span(no_identity, identity.LogicalInference),
      identity.Enrichment(None, None),
    )
  })
}

pub fn official_baggage_duplicate_resolution_is_last_valid_value_test() {
  harness.with_composite(fn() {
    let #(_, extracted) =
      proxy_ingress.extract([
        #("baggage", "session.id=first,session.id=last"),
      ])
    should.equal(
      identity.for_span(extracted, identity.LogicalInference),
      identity.Enrichment(Some(must_identifier("last")), None),
    )
  })
}

fn must_identifier(value: String) -> identity.Identifier {
  let assert Ok(identifier) = identity.identifier(value)
  identifier
}

@external(erlang, "pig_otel_test_ffi", "has_baggage")
fn has_baggage(context: context.Context) -> Bool
