//// Scripted transport tests for OpenAI streaming adapters.

import gleam/bit_array
import gleam/erlang/process
import gleeunit
import pig/openai
import pig/provider
import pig_protocol/error
import pig_protocol/inference as protocol_inference
import pig_protocol/message
import pig_transport

pub fn main() -> Nil {
  gleeunit.main()
}

fn request() -> provider.InferenceRequest {
  provider.InferenceRequest(
    messages: [message.User("hello")],
    tools: [],
    settings: provider.default_settings(),
  )
}

fn transport(status: Int, body: String) -> pig_transport.Transport {
  pig_transport.Transport(
    sync: fn(_) { pig_transport.TransportError("unused") },
    stream: fn(_, events) {
      process.send(events, pig_transport.SourceHead(status, []))
      process.send(
        events,
        pig_transport.SourceChunk(bit_array.from_string(body)),
      )
      process.send(events, pig_transport.SourceDone)
    },
  )
}

fn recording_transport(
  seen: process.Subject(Int),
  body: String,
) -> pig_transport.Transport {
  pig_transport.Transport(
    sync: fn(_) { pig_transport.TransportError("unused") },
    stream: fn(request, events) {
      process.send(seen, request.timeout_ms)
      process.send(events, pig_transport.SourceHead(200, []))
      process.send(
        events,
        pig_transport.SourceChunk(bit_array.from_string(body)),
      )
      process.send(events, pig_transport.SourceDone)
    },
  )
}

type TimeoutPhase {
  HeadWait
  BodyWait
}

fn timeout_transport(
  phase: TimeoutPhase,
  started: process.Subject(Int),
  cancelled: process.Subject(Nil),
) -> pig_transport.Transport {
  pig_transport.Transport(
    sync: fn(_) { pig_transport.TransportError("unused") },
    stream: fn(request, events) {
      let control = process.new_subject()
      process.send(events, pig_transport.SourceReady(control))
      process.send(started, request.timeout_ms)
      case phase {
        HeadWait -> Nil
        BodyWait -> {
          process.send(events, pig_transport.SourceHead(200, []))
          process.send(
            events,
            pig_transport.SourceChunk(bit_array.from_string("data: {")),
          )
        }
      }
      let assert Ok(pig_transport.CancelSource) = process.receive(control, 1000)
      process.send(cancelled, Nil)
    },
  )
}

pub fn chat_emits_incremental_normalized_deltas_and_result_test() {
  let body =
    "data: {\"id\":\"chat-1\",\"model\":\"gpt-4o\",\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n"
    <> "data: {\"id\":\"chat-1\",\"model\":\"gpt-4o\",\"choices\":[{\"delta\":{\"content\":\"lo\"},\"finish_reason\":\"stop\"}]}\n\n"
    <> "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}\n\n"
    <> "data: [DONE]\n\n"
  let prov =
    openai.provider_with_transport(
      openai.ChatCompletions,
      "key",
      "gpt-4o",
      "http://example.test/v1",
      1000,
      transport(200, body),
    )
  let inference = provider.start(prov, request())
  let assert Ok(provider.Delta(protocol_inference.TextDelta("Hel"))) =
    provider.receive(inference, 1000)
  let assert Ok(provider.Delta(protocol_inference.TextDelta("lo"))) =
    provider.receive(inference, 1000)
  let assert Ok(provider.Finished(Ok(result))) =
    provider.receive(inference, 1000)
  let assert message.Assistant(content: "Hello", ..) = result.message
}

pub fn responses_emits_incremental_delta_and_canonical_result_test() {
  let body =
    "data: {\"type\":\"response.created\",\"response\":{\"id\":\"r1\",\"model\":\"gpt-5\"}}\n\n"
    <> "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[]}}\n\n"
    <> "data: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"delta\":\"Hi\"}\n\n"
    <> "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"model\":\"gpt-5\",\"status\":\"completed\",\"output\":[],\"usage\":{\"input_tokens\":1,\"output_tokens\":1,\"total_tokens\":2}}}\n\n"
  let prov =
    openai.provider_with_transport(
      openai.Responses,
      "key",
      "gpt-5",
      "http://example.test/v1",
      1000,
      transport(200, body),
    )
  let inference = provider.start(prov, request())
  let assert Ok(provider.Delta(protocol_inference.TextDelta("Hi"))) =
    provider.receive(inference, 1000)
  let assert Ok(provider.Finished(Ok(result))) =
    provider.receive(inference, 1000)
  let assert message.Assistant(content: "Hi", ..) = result.message
}

pub fn custom_timeout_above_default_is_sent_to_transport_test() {
  let seen = process.new_subject()
  let body =
    "data: {\"id\":\"chat-1\",\"model\":\"gpt-4o\",\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":\"stop\"}]}\n\n"
    <> "data: [DONE]\n\n"
  let prov =
    openai.provider_with_transport(
      openai.ChatCompletions,
      "key",
      "gpt-4o",
      "http://example.test/v1",
      120_001,
      recording_transport(seen, body),
    )
  let inference = provider.start(prov, request())
  let assert Ok(120_001) = process.receive(seen, 1000)
  let assert Ok(_) = provider.collect(inference, 1000)
}

pub fn custom_timeout_is_used_for_head_wait_and_cancels_source_test() {
  let started = process.new_subject()
  let cancelled = process.new_subject()
  let prov =
    openai.provider_with_transport(
      openai.ChatCompletions,
      "key",
      "gpt-4o",
      "http://example.test/v1",
      25,
      timeout_transport(HeadWait, started, cancelled),
    )
  let inference = provider.start(prov, request())
  let assert Ok(25) = process.receive(started, 1000)
  let assert Error(error.Timeout) = provider.collect(inference, 1000)
  let assert Ok(Nil) = process.receive(cancelled, 1000)
}

pub fn custom_timeout_is_used_for_body_wait_and_cancels_source_test() {
  let started = process.new_subject()
  let cancelled = process.new_subject()
  let prov =
    openai.provider_with_transport(
      openai.Responses,
      "key",
      "gpt-5",
      "http://example.test/v1",
      25,
      timeout_transport(BodyWait, started, cancelled),
    )
  let inference = provider.start(prov, request())
  let assert Ok(25) = process.receive(started, 1000)
  let assert Error(error.Timeout) = provider.collect(inference, 1000)
  let assert Ok(Nil) = process.receive(cancelled, 1000)
}

pub fn non_2xx_status_maps_to_typed_provider_error_test() {
  let prov =
    openai.provider_with_transport(
      openai.ChatCompletions,
      "key",
      "gpt-4o",
      "http://example.test/v1",
      1000,
      transport(429, "{\"error\":{\"message\":\"quota\"}}"),
    )
  let assert Error(error.RateLimited) = provider.run(prov, request(), 1000)
}
