//// Central check boundary for opt-in proxy conversation lifecycle tests.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import gleeunit/should
import pig_otel
import pig_otel/content/options
import pig_proxy/config
import pig_proxy/execution
import pig_proxy/trace_metadata
import pig_proxy/tracing
import pig_transport as transport
import simplifile
import support/in_memory_transport

pub fn fixture(name: String) -> String {
  let assert Ok(value) = simplifile.read("test_data/content_lifecycle/" <> name)
  value
}

pub fn run_retrying_buffered_capture() -> List(String) {
  let request_body = fixture("chat_input.json")
  let selected_body = fixture("chat_output.json")
  let failed_body = "{\"error\":\"PRIVATE_RETRY_ENVELOPE\"}"
  with_annotations(fn() {
    let name = process.new_name("content_lifecycle_owner")
    let assert Ok(_) =
      static_supervisor.new(static_supervisor.OneForOne)
      |> static_supervisor.add(tracing.supervisor(name))
      |> static_supervisor.start
    let capture_options = options.defaults()
    let owner =
      tracing.register_with_policy(
        name,
        pig_otel.Conversation(capture_options),
        [],
        "/v1/chat/completions",
      )
    let assert tracing.Current(_) =
      tracing.call(
        owner,
        tracing.BeginInference(
          pig_otel.ChatCompletions,
          None,
          "fixture_model",
          None,
        ),
      )
    let assert Ok(script) =
      in_memory_transport.start(
        [
          transport.Response(
            500,
            [#("content-type", "application/json")],
            bit_array.from_string(failed_body),
          ),
          transport.Response(
            200,
            [#("content-type", "application/json")],
            bit_array.from_string(selected_body),
          ),
        ],
        transport.TransportError("exhausted"),
      )
    let request =
      execution.ProxyRequest(
        "POST",
        "/v1/chat/completions",
        [],
        request_body,
        "fixture_model",
      )
    let executor =
      execution.executor(in_memory_transport.transport(script), None)
      |> execution.with_tracing(owner)
      |> execution.with_retries_per_target(1)
    let outcome =
      execution.orchestrate(
        execution.Executor(..executor, sleep: fn(_) { Nil }),
        request,
        execution.FallbackChain([
          config.openai_target("fixture", "http://fixture/v1", "PRIVATE_KEY"),
        ]),
      )
    let assert execution.Committed(status:, headers:, body:, ..) = outcome
    let _ =
      tracing.call(
        owner,
        tracing.SelectedBufferedResponse(
          False,
          status,
          headers,
          body,
          "fixture",
          Some("openai"),
        ),
      )
    let _ =
      tracing.call(
        owner,
        tracing.LogicalTerminal(
          tracing.http_outcome(status),
          trace_metadata.buffered(
            pig_otel.ChatCompletions,
            result.unwrap(bit_array.to_string(body), ""),
          ),
          status,
        ),
      )
    let _ =
      tracing.call(owner, tracing.Downstream(tracing.http_outcome(status)))
    Nil
  })
}

pub fn run_no_target_capture() -> List(String) {
  let request_body = fixture("chat_input.json")
  with_annotations(fn() {
    let name = process.new_name("content_lifecycle_skip_owner")
    let assert Ok(_) =
      static_supervisor.new(static_supervisor.OneForOne)
      |> static_supervisor.add(tracing.supervisor(name))
      |> static_supervisor.start
    let owner =
      tracing.register_with_policy(
        name,
        pig_otel.Conversation(options.defaults()),
        [],
        "/v1/chat/completions",
      )
    let assert tracing.Current(_) =
      tracing.call(
        owner,
        tracing.BeginInference(
          pig_otel.ChatCompletions,
          None,
          "fixture_model",
          None,
        ),
      )
    let assert Ok(script) =
      in_memory_transport.start([], transport.TransportError("unused"))
    let executor =
      execution.executor(in_memory_transport.transport(script), None)
      |> execution.with_tracing(owner)
    let outcome =
      execution.orchestrate(
        executor,
        execution.ProxyRequest(
          "POST",
          "/v1/chat/completions",
          [],
          request_body,
          "fixture_model",
        ),
        execution.FallbackChain([]),
      )
    let assert execution.NoTargets(..) = outcome
    let _ =
      tracing.call(
        owner,
        tracing.LogicalTerminal(
          pig_otel.Failed("upstream_error"),
          trace_metadata.empty(),
          503,
        ),
      )
    let _ =
      tracing.call(owner, tracing.Downstream(pig_otel.Failed("upstream_error")))
    Nil
  })
}

pub type Eligibility {
  Eligibility(
    name: String,
    request_headers: List(#(String, String)),
    response_headers: List(#(String, String)),
    input: Bool,
    output: Bool,
  )
}

pub fn eligibility_cases() -> List(Eligibility) {
  let pair = {
    use key <- decode.field(0, decode.string)
    use value <- decode.field(1, decode.string)
    decode.success(#(key, value))
  }
  let row = {
    use name <- decode.field("name", decode.string)
    use request_headers <- decode.field("request_headers", decode.list(pair))
    use response_headers <- decode.field("response_headers", decode.list(pair))
    use input <- decode.field("input", decode.bool)
    use output <- decode.field("output", decode.bool)
    decode.success(Eligibility(
      name,
      request_headers,
      response_headers,
      input,
      output,
    ))
  }
  let assert Ok(rows) =
    json.parse(fixture("eligibility.json"), decode.list(row))
  rows
}

pub fn check_eligibility(api: pig_otel.Api, row: Eligibility) -> List(String) {
  let body = case api {
    pig_otel.Responses -> fixture("responses_output.json")
    _ -> fixture("chat_output.json")
  }
  run_selected(
    api,
    row.request_headers,
    row.response_headers,
    bit_array.from_string(body),
  )
}

pub fn check_oversized_before_utf8() -> List(String) {
  let assert Ok(body) =
    simplifile.read_bits(
      "test_data/content_lifecycle/oversized_invalid_utf8.body",
    )
  let assert Ok(capture_options) =
    options.with_direction_limits(
      options.defaults(),
      options.OutputLimits(65_536, 65_536),
    )
  run_selected_with_options(
    capture_options,
    pig_otel.ChatCompletions,
    [],
    [#("content-type", "application/json")],
    body,
  )
}

fn run_selected(
  api: pig_otel.Api,
  request_headers: List(#(String, String)),
  response_headers: List(#(String, String)),
  response_body: BitArray,
) -> List(String) {
  run_selected_with_options(
    options.defaults(),
    api,
    request_headers,
    response_headers,
    response_body,
  )
}

fn run_selected_with_options(
  options: options.Options,
  api: pig_otel.Api,
  request_headers: List(#(String, String)),
  response_headers: List(#(String, String)),
  response_body: BitArray,
) -> List(String) {
  let #(path, request_body) = case api {
    pig_otel.Responses -> #("/v1/responses", fixture("responses_input.json"))
    _ -> #("/v1/chat/completions", fixture("chat_input.json"))
  }
  with_annotations(fn() {
    let name = process.new_name("content_eligibility_owner")
    let assert Ok(_) =
      static_supervisor.new(static_supervisor.OneForOne)
      |> static_supervisor.add(tracing.supervisor(name))
      |> static_supervisor.start
    let owner =
      tracing.register_with_policy(
        name,
        pig_otel.Conversation(options),
        [],
        path,
      )
    let assert tracing.Current(_) =
      tracing.call(
        owner,
        tracing.BeginInference(api, None, "fixture_model", None),
      )
    let assert Ok(script) =
      in_memory_transport.start(
        [
          transport.Response(200, response_headers, response_body),
        ],
        transport.TransportError("unused"),
      )
    let executor =
      execution.executor(in_memory_transport.transport(script), None)
      |> execution.with_tracing(owner)
      |> execution.with_retries_per_target(0)
    let outcome =
      execution.orchestrate(
        executor,
        execution.ProxyRequest(
          "POST",
          path,
          request_headers,
          request_body,
          "fixture_model",
        ),
        execution.FallbackChain([
          config.openai_target("fixture", "http://fixture/v1", "PRIVATE_KEY"),
        ]),
      )
    let assert execution.Committed(status:, headers:, body:, ..) = outcome
    should.equal(body, response_body)
    let _ =
      tracing.call(
        owner,
        tracing.SelectedBufferedResponse(
          False,
          status,
          headers,
          body,
          "fixture",
          Some("openai"),
        ),
      )
    let _ =
      tracing.call(
        owner,
        tracing.LogicalTerminal(
          tracing.http_outcome(status),
          trace_metadata.empty(),
          status,
        ),
      )
    let _ =
      tracing.call(owner, tracing.Downstream(tracing.http_outcome(status)))
    Nil
  })
}

pub fn run_large_completion(policy: pig_otel.Policy) -> List(String) {
  let ignored = string.repeat("x", 70_000)
  let event =
    "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{"
    <> "\"id\":\"fixture-response-id\","
    <> "\"model\":\"fixture-response-model\","
    <> "\"status\":\"completed\","
    <> "\"usage\":{\"input_tokens\":20,\"output_tokens\":7,\"input_tokens_details\":{\"cached_tokens\":6}},"
    <> "\"ignored_output\":\"PRIVATE_IGNORED_OUTPUT"
    <> ignored
    <> "\"}}\n\n"
  let body = bit_array.from_string(event)
  with_annotations(fn() {
    let name = process.new_name("large_completion_owner")
    let assert Ok(_) =
      static_supervisor.new(static_supervisor.OneForOne)
      |> static_supervisor.add(tracing.supervisor(name))
      |> static_supervisor.start
    let owner = tracing.register_with_policy(name, policy, [], "/v1/responses")
    let assert tracing.Current(_) =
      tracing.call(
        owner,
        tracing.BeginInference(
          pig_otel.Responses,
          Some("openai"),
          "fixture-request-model",
          None,
        ),
      )
    let assert Ok(script) =
      in_memory_transport.start_stream(
        [
          in_memory_transport.CommitStream(
            200,
            [#("content-type", "text/event-stream")],
            [body],
            in_memory_transport.StreamDone,
          ),
        ],
        in_memory_transport.stream_exhausted_default,
      )
    let outcome =
      execution.orchestrate_stream(
        execution.executor(in_memory_transport.transport(script), None)
          |> execution.with_tracing(owner),
        execution.ProxyRequest(
          "POST",
          "/v1/responses",
          [#("accept", "text/event-stream")],
          "{}",
          "fixture-request-model",
        ),
        execution.FallbackChain([
          config.openai_target("fixture", "http://fixture/v1", "PRIVATE_KEY"),
        ]),
      )
    let assert execution.CommittedStream(target_id:, provider:, status:, ..) =
      outcome
    let _ =
      tracing.call(owner, tracing.SelectStream(target_id, provider, status))
    let sink = process.new_subject()
    let _ = tracing.call(owner, tracing.Bind(sink))
    accept_stream(owner, sink)
    let assert tracing.Body(transport.Chunk(_)) = process.receive_forever(sink)
    should.equal(process.receive_forever(sink), tracing.Body(transport.Done))
    let _ =
      tracing.call(owner, tracing.Downstream(tracing.http_outcome(status)))
    Nil
  })
}

fn accept_stream(
  owner: tracing.Owner,
  sink: process.Subject(tracing.ChunkMessage),
) -> Nil {
  let setup_ack = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let reply = tracing.call(owner, tracing.Accepted)
      process.send(setup_ack, reply)
    })
  should.equal(process.receive_forever(sink), tracing.Receipt)
  let _ = tracing.call(owner, tracing.HandoffReceipt)
  should.equal(process.receive_forever(setup_ack), tracing.Ack)
}

@external(erlang, "pig_proxy_content_lifecycle_ffi", "with_inference_annotations")
fn with_annotations(work: fn() -> Nil) -> List(String)
