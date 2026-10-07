//// Proxy-only baggage adoption at the HTTP ingress boundary.

import gleam/option.{type Option, None, Some}
import otel/baggage.{type Entry}
import otel/context.{type Context}
import otel/propagation
import pig_otel/identity

/// Extract with the configured official propagator, retain validated Pig
/// identity from baggage, and return a context with all baggage removed.
/// Direct Pig clients should continue using `pig_otel.ingress`.
pub fn extract(
  headers: List(#(String, String)),
) -> #(Context, identity.Identity) {
  let extracted = propagation.extract(headers)
  let session = baggage.get(extracted, "session.id")
  let conversation = baggage.get(extracted, "gen_ai.conversation.id")
  let clean_context = baggage.clear(extracted)
  let identity =
    identity.empty()
    |> with_session(session)
    |> with_conversation(conversation)
  #(clean_context, identity)
}

fn with_session(
  current: identity.Identity,
  entry: Option(Entry),
) -> identity.Identity {
  case entry {
    Some(baggage.Entry(value, _)) ->
      identity.with_session(current, identity.identifier(value))
    None -> current
  }
}

fn with_conversation(
  current: identity.Identity,
  entry: Option(Entry),
) -> identity.Identity {
  case entry {
    Some(baggage.Entry(value, _)) ->
      identity.with_conversation(current, identity.identifier(value))
    None -> current
  }
}
