//// All business setup lives here so API changes affect one check harness.
//// Provider/tool callbacks are real Pig callbacks; proxy runs its real server.

import gleam/bit_array
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/string
import jscheam/schema
import local_validation/host
import pig
import pig/hooks
import pig/openai
import pig/provider
import pig/tool
import pig_otel
import pig_otel/content/options
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
import pig_transport

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

/// Exercise both real routes with explicit logical conversation capture.
pub fn exercise_proxy_content() -> Nil {
  check_proxy_content(fn(port, upstream) {
    start_proxy_content(port, upstream, options.defaults(), 0, None)
  })
}

/// Small capture limits must omit content without changing upstream HTTP.
pub fn exercise_proxy_content_interrupt() -> Nil {
  check_proxy_content_interrupt(fn(port, upstream) {
    start_proxy_content(port, upstream, options.defaults(), 0, None)
  })
}

pub fn exercise_proxy_content_malformed() -> Nil {
  check_proxy_content_malformed(fn(port, upstream) {
    start_proxy_content(port, upstream, options.defaults(), 0, None)
  })
}

pub fn exercise_proxy_content_retry() -> Nil {
  check_proxy_content_retry(fn(port, upstream) {
    start_proxy_content(port, upstream, options.defaults(), 1, None)
  })
}

/// Last builder wins even when an earlier builder requested conversation capture.
pub fn exercise_proxy_content_disabled() -> Nil {
  check_proxy_content(fn(port, upstream) {
    start_proxy_content(
      port,
      upstream,
      options.defaults(),
      0,
      Some(pig_otel.Disabled),
    )
  })
}

pub fn exercise_proxy_content_no_sdk() -> Nil {
  check_proxy_content(fn(port, upstream) {
    start_proxy_content(port, upstream, options.defaults(), 0, None)
  })
}

pub fn exercise_proxy_content_overflow() -> Nil {
  let assert Ok(options) = options.with_limits(options.defaults(), 32, 16)
  check_proxy_content_overflow(fn(port, upstream) {
    start_proxy_content(port, upstream, options, 0, None)
  })
}

/// Exercise real OpenAI-compatible providers through both APIs and run modes.
pub fn exercise_direct_content() -> Nil {
  exercise_direct_content_with(pig_otel.Conversation(options.defaults()))
}

/// Exercise real providers with metadata-only tracing through both APIs and modes.
pub fn exercise_direct_content_metadata() -> Nil {
  exercise_direct_content_with(pig_otel.MetadataOnly)
}

/// Disabled policy keeps the same provider/tool business interaction intact.
pub fn exercise_direct_content_disabled() -> Nil {
  exercise_direct_content_with(pig_otel.Disabled)
}

fn exercise_direct_content_with(policy: pig_otel.Policy) -> Nil {
  list.each([openai.ChatCompletions, openai.Responses], fn(api) {
    list.each([False, True], fn(streaming) {
      host.with_caller_parent(streaming, fn() {
        run_direct_content(api, streaming, policy)
      })
    })
  })
}

fn run_direct_content(
  api: openai.OpenAIApi,
  streaming: Bool,
  policy: pig_otel.Policy,
) -> Nil {
  let transport = direct_transport(api)
  let model = case api {
    openai.ChatCompletions -> "direct_model_chat"
    openai.Responses -> "direct_model_responses"
  }
  let local_provider =
    openai.provider_with_transport(
      api,
      "direct_test_key",
      model,
      "http://direct-content.invalid/v1",
      5000,
      transport,
    )
  let local_tool =
    tool.Tool(
      definition: tool_definition.ToolDefinition(
        "fixture_tool",
        "NEVER_EXPORT_DIRECT_DESCRIPTION",
        schema.object([
          schema.prop("safe", schema.string()),
          schema.prop("api_key", schema.string()),
        ]),
      ),
      handler: fn(_, _) {
        host.callback("tool")
        Ok(
          json.object([
            #("safe", json.string("CAPTURE_ALLOWED_DIRECT_RESULT")),
            #("password", json.string("NEVER_EXPORT_DIRECT_RESULT_SECRET")),
          ]),
        )
      },
    )
  let hooks =
    hooks.new("direct_content_input_capture")
    |> hooks.on_before_inference(fn(event) {
      let messages =
        list.map(event.messages, fn(message) {
          case message {
            message.User(_) -> message.User("CAPTURE_ALLOWED_DIRECT_INPUT")
            _ -> message
          }
        })
      let has_developer =
        list.any(messages, fn(message) {
          case message {
            message.Developer("CAPTURE_ALLOWED_DIRECT_DEVELOPER") -> True
            _ -> False
          }
        })
      let messages = case has_developer {
        True -> messages
        False -> [
          message.Developer("CAPTURE_ALLOWED_DIRECT_DEVELOPER"),
          ..messages
        ]
      }
      hooks.replace_messages(messages)
    })
  let assert Ok(agent) =
    pig.new(local_provider)
    |> pig.with_tracing(policy)
    |> pig.with_agent_name("direct_content_validation")
    |> pig.with_system_prompt("CAPTURE_ALLOWED_DIRECT_SYSTEM")
    |> pig.with_tool(local_tool)
    |> pig.with_hooks(hooks)
    |> pig.start
  let first = direct_run(agent, streaming, "PRIVATE_ORIGINAL_PROMPT")
  let assert message.Assistant(
    "CAPTURE_ALLOWED_DIRECT_COMPLETION",
    [],
    _,
    Some(stop_reason.Stop),
  ) = first
  pig.stop(agent)
}

fn direct_run(
  agent: pig.Agent,
  streaming: Bool,
  prompt: String,
) -> message.Message {
  case streaming {
    False -> {
      let assert Ok(answer) = pig.run(agent, prompt)
      answer
    }
    True -> {
      let sink = process.new_subject()
      let assert Ok(run) = pig.stream(agent, prompt, sink)
      let assert Ok(answer) = pig.collect(run, sink, 5000)
      answer
    }
  }
}

fn direct_transport(api: openai.OpenAIApi) -> pig_transport.Transport {
  pig_transport.Transport(
    sync: fn(_) { pig_transport.TransportError("unused") },
    stream: fn(request, events) {
      host.propagated_context(request.headers)
      let first_round =
        !string.contains(request.body, "CAPTURE_ALLOWED_DIRECT_RESULT")
      let body = case api, first_round {
        openai.ChatCompletions, True -> direct_chat_first
        openai.ChatCompletions, False -> direct_chat_final
        openai.Responses, True -> direct_responses_first
        openai.Responses, False -> direct_responses_final
      }
      let control = process.new_subject()
      process.send(events, pig_transport.SourceReady(control))
      process.send(events, pig_transport.SourceHead(200, []))
      process.send(
        events,
        pig_transport.SourceChunk(bit_array.from_string(body)),
      )
      process.send(events, pig_transport.SourceDone)
    },
  )
}

const direct_chat_first = "data: {\"id\":\"direct_round_1\",\"object\":\"chat.completion.chunk\",\"model\":\"direct_model_chat\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"CAPTURE_ALLOWED_DIRECT_CALL\",\"reasoning_content\":\"NEVER_EXPORT_DIRECT_REASONING\",\"tool_calls\":[{\"index\":0,\"id\":\"fixture_call\",\"type\":\"function\",\"function\":{\"name\":\"fixture_tool\",\"arguments\":\"{\\\"safe\\\":\\\"CAPTURE_ALLOWED_DIRECT_ARGUMENT\\\",\\\"api_key\\\":\\\"NEVER_EXPORT_DIRECT_ARGUMENT_SECRET\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3,\"prompt_tokens_details\":{\"cached_tokens\":2}}}\n\ndata: [DONE]\n\n"

const direct_chat_final = "data: {\"id\":\"direct_round_2\",\"object\":\"chat.completion.chunk\",\"model\":\"direct_model_chat\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"CAPTURE_ALLOWED_DIRECT_COMPLETION\",\"reasoning_content\":\"NEVER_EXPORT_DIRECT_REASONING\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3,\"prompt_tokens_details\":{\"cached_tokens\":2}}}\n\ndata: [DONE]\n\n"

const direct_responses_first = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"direct_message_1\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"item_id\":\"direct_message_1\",\"content_index\":0,\"delta\":\"CAPTURE_ALLOWED_DIRECT_CALL\"}\n\ndata: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"id\":\"direct_call_item\",\"type\":\"function_call\",\"call_id\":\"fixture_call\",\"name\":\"fixture_tool\",\"arguments\":\"\",\"status\":\"in_progress\"}}\n\ndata: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"direct_message_1\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"CAPTURE_ALLOWED_DIRECT_CALL\"}]}}\n\ndata: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"id\":\"direct_call_item\",\"type\":\"function_call\",\"call_id\":\"fixture_call\",\"name\":\"fixture_tool\",\"arguments\":\"{\\\"safe\\\":\\\"CAPTURE_ALLOWED_DIRECT_ARGUMENT\\\",\\\"api_key\\\":\\\"NEVER_EXPORT_DIRECT_ARGUMENT_SECRET\\\"}\",\"status\":\"completed\"}}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"direct_round_1\",\"model\":\"direct_model_responses\",\"status\":\"completed\",\"output\":[{\"type\":\"reasoning\",\"summary\":[{\"type\":\"summary_text\",\"text\":\"NEVER_EXPORT_DIRECT_REASONING\"}]},{\"type\":\"message\",\"id\":\"direct_message_1\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"CAPTURE_ALLOWED_DIRECT_CALL\"}]},{\"type\":\"function_call\",\"id\":\"direct_call_item\",\"call_id\":\"fixture_call\",\"name\":\"fixture_tool\",\"arguments\":\"{\\\"safe\\\":\\\"CAPTURE_ALLOWED_DIRECT_ARGUMENT\\\",\\\"api_key\\\":\\\"NEVER_EXPORT_DIRECT_ARGUMENT_SECRET\\\"}\",\"status\":\"completed\"}],\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":2}}}}\n\n"

const direct_responses_final = "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"direct_message_2\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"in_progress\",\"content\":[]}}\n\ndata: {\"type\":\"response.output_text.delta\",\"output_index\":0,\"item_id\":\"direct_message_2\",\"content_index\":0,\"delta\":\"CAPTURE_ALLOWED_DIRECT_COMPLETION\"}\n\ndata: {\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"direct_message_2\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"CAPTURE_ALLOWED_DIRECT_COMPLETION\"}]}}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"direct_round_2\",\"model\":\"direct_model_responses\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"id\":\"direct_message_2\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"CAPTURE_ALLOWED_DIRECT_COMPLETION\"}]}],\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":2}}}}\n\n"

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

fn start_proxy_content(
  port: Int,
  upstream: String,
  options: options.Options,
  retries: Int,
  last_policy: option.Option(pig_otel.Policy),
) -> Nil {
  let configured =
    config.new([config.openai_target("fixture", upstream, "PRIVATE_API_KEY")])
    |> config.with_tracing(pig_otel.Conversation(options))
    |> config.with_port(port)
    |> config.with_bind("127.0.0.1")
    |> config.with_retries_per_target(retries)
  let cfg = case last_policy {
    None -> configured
    Some(policy) -> config.with_tracing(configured, policy)
  }
  start_proxy_with_config(port, cfg)
}

fn start_proxy(port: Int, upstream: String, policy: pig_otel.Policy) -> Nil {
  let cfg =
    config.new([config.openai_target("fixture", upstream, "PRIVATE_API_KEY")])
    |> config.with_tracing(policy)
    |> config.with_port(port)
    |> config.with_bind("127.0.0.1")
    |> config.with_retries_per_target(0)
  start_proxy_with_config(port, cfg)
}

fn start_proxy_with_config(_port: Int, cfg: config.ProxyConfig) -> Nil {
  let owners = process.new_name("validation_owners")
  let assert Ok(started) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(tracing.supervisor(owners))
    |> static_supervisor.start
  // The fixture owns this external root and stops it before its starter exits.
  process.unlink(started.pid)
  host.register_proxy_owners(started.pid)
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
    circuit: process.new_name("unused_circuit"),
    catalog: process.new_name("unused_catalog"),
    metrics: process.new_name("unused_metrics"),
    vault: None,
  ))
}

@external(erlang, "pig_otel_validation_http", "check_proxy_sync")
fn check_proxy_sync(start: fn(Int, String) -> Nil) -> Nil

@external(erlang, "pig_otel_validation_http", "check_proxy_content")
fn check_proxy_content(start: fn(Int, String) -> Nil) -> Nil

@external(erlang, "pig_otel_validation_http", "check_proxy_content_interrupt")
fn check_proxy_content_interrupt(start: fn(Int, String) -> Nil) -> Nil

@external(erlang, "pig_otel_validation_http", "check_proxy_content_malformed")
fn check_proxy_content_malformed(start: fn(Int, String) -> Nil) -> Nil

@external(erlang, "pig_otel_validation_http", "check_proxy_content_retry")
fn check_proxy_content_retry(start: fn(Int, String) -> Nil) -> Nil

@external(erlang, "pig_otel_validation_http", "check_proxy_content_overflow")
fn check_proxy_content_overflow(start: fn(Int, String) -> Nil) -> Nil

@external(erlang, "pig_otel_validation_http", "check_proxy")
fn check_proxy(start: fn(Int, String) -> Nil) -> Nil
