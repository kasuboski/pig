//// All business setup lives here so API changes affect one check harness.
//// Provider/tool callbacks are real Pig callbacks; proxy runs its real server.

import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import jscheam/schema
import local_validation/host
import pig
import pig/provider
import pig/tool
import pig_otel
import pig_protocol/error
import pig_protocol/inference
import pig_protocol/message
import pig_protocol/stop_reason
import pig_protocol/tool_definition
import pig_proxy/config
import pig_proxy/metric_labels
import pig_proxy/model_catalog
import pig_proxy/server
import pig_proxy/telemetry
import pig_proxy/tracing

/// Exercise buffered and streamed agent runs and both real proxy routes.
pub fn exercise() -> Nil {
  exercise_with(pig_otel.MetadataOnly)
}

/// Run only real Pig callbacks, useful when proxy integration is not yet ready.
pub fn exercise_agents() -> Nil {
  check_agent(False, pig_otel.MetadataOnly)
  check_agent(True, pig_otel.MetadataOnly)
}

/// A real provider failure must close both Pig spans with bounded error status.
pub fn exercise_failure() -> Nil {
  host.with_caller_parent(False, fn() {
    let local =
      provider.from_buffered(fn(_) {
        host.callback("provider")
        Error(error.ApiError("PRIVATE_PROVIDER_ERROR"))
      })
    let assert Ok(agent) = pig.start(pig.new(local))
    let assert Error(_) = pig.run(agent, "PRIVATE_PROMPT")
    pig.stop(agent)
  })
}

/// Independently exercise actual proxy sync requests on both routes.
pub fn exercise_proxy_sync() -> Nil {
  check_proxy_sync(fn(port, upstream) {
    start_proxy(port, upstream, pig_otel.MetadataOnly)
  })
}

/// The same real business graph with span creation explicitly disabled.
pub fn exercise_disabled() -> Nil {
  exercise_with(pig_otel.Disabled)
}

fn exercise_with(policy: pig_otel.Policy) -> Nil {
  check_agent(False, policy)
  check_agent(True, policy)
  check_proxy(fn(port, upstream) { start_proxy(port, upstream, policy) })
}

fn check_agent(streaming: Bool, policy: pig_otel.Policy) -> Nil {
  host.with_caller_parent(streaming, fn() { run_agent(streaming, policy) })
}

fn run_agent(streaming: Bool, policy: pig_otel.Policy) -> Nil {
  let local_provider = case streaming {
    True ->
      provider.from_streaming(fn(request, emit) {
        emit(provider.Delta(inference.TextDelta("PRIVATE_COMPLETION")))
        emit(provider.Finished(Ok(answer(request))))
      })
    False -> provider.from_buffered(fn(request) { Ok(answer(request)) })
  }
  let local_tool =
    tool.Tool(
      definition: tool_definition.ToolDefinition(
        "fixture_tool",
        "PRIVATE_TOOL_DESCRIPTION",
        schema.object([]),
      ),
      handler: fn(_, _) {
        host.callback("tool")
        Ok(json.string("PRIVATE_TOOL_RESULT"))
      },
    )
  let assert Ok(agent) =
    pig.new(local_provider)
    |> pig.with_tracing(policy)
    |> pig.with_agent_name("local_validation")
    |> pig.with_system_prompt("PRIVATE_SYSTEM")
    |> pig.with_tool(local_tool)
    |> pig.start
  let result = case streaming {
    False -> pig.run(agent, "PRIVATE_PROMPT")
    True -> {
      let sink = process.new_subject()
      let assert Ok(run) = pig.stream(agent, "PRIVATE_PROMPT", sink)
      pig.collect(run, sink, 5000)
    }
  }
  let assert Ok(message.Assistant("PRIVATE_COMPLETION", [], _, _)) = result
  // Stop acknowledgement is the supported terminal cleanup boundary, not a
  // promise that every underlying connection has drained successfully.
  pig.stop(agent)
}

fn answer(request: provider.InferenceRequest) -> provider.InferenceResult {
  host.callback("provider")
  let has_tool =
    list.any(request.messages, fn(msg) {
      case msg {
        message.Tool(..) -> True
        _ -> False
      }
    })
  let msg = case has_tool {
    False ->
      message.Assistant(
        "PRIVATE_REASONING",
        [
          message.ToolCall(
            "fixture_call",
            "fixture_tool",
            "{\"secret\":\"PRIVATE_ARGUMENT\"}",
          ),
        ],
        None,
        Some(stop_reason.ToolUse),
      )
    True ->
      message.Assistant("PRIVATE_COMPLETION", [], None, Some(stop_reason.Stop))
  }
  let metadata =
    provider.default_metadata()
    |> provider.with_response_id("fixture_response")
    |> provider.with_response_model("fixture_model")
    |> provider.with_input_tokens(5)
    |> provider.with_output_tokens(3)
    |> provider.with_cached_input_tokens(2)
  inference.InferenceResult(message: msg, metadata:)
}

fn start_proxy(port: Int, upstream: String, policy: pig_otel.Policy) -> Nil {
  let owners = process.new_name("validation_owners")
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(tracing.supervisor(owners))
    |> static_supervisor.start
  let cfg =
    config.new([config.openai_target("fixture", upstream, "PRIVATE_API_KEY")])
    |> config.with_tracing(policy)
    |> config.with_port(port)
    |> config.with_bind("127.0.0.1")
    |> config.with_retries_per_target(0)
  server.start(server.ServerState(
    supervisor: None,
    config: cfg,
    emitter: telemetry.emitter(
      metric_labels.Identities(model_catalog.empty, [], ["fixture"], [
        "openai",
        "",
      ]),
      fn(_) { Nil },
    ),
    owners:,
    routes: [],
    circuit: process.new_name("unused_circuit"),
    catalog: process.new_name("unused_catalog"),
    metrics: process.new_name("unused_metrics"),
    vault: None,
  ))
}

@external(erlang, "pig_otel_validation_http", "check_proxy_sync")
fn check_proxy_sync(start: fn(Int, String) -> Nil) -> Nil

@external(erlang, "pig_otel_validation_http", "check_proxy")
fn check_proxy(start: fn(Int, String) -> Nil) -> Nil
