//// Streaming OpenAI-compatible Chat Completions and Responses providers.
////
//// HTTP bytes are owned by `pig_transport`; SSE framing and provider
//// accumulation are owned by `pig_protocol`. This module only coordinates
//// those two seams and emits normalized provider events.

import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pig/provider
import pig_protocol/auth
import pig_protocol/codec/chat
import pig_protocol/codec/chat_stream
import pig_protocol/codec/responses
import pig_protocol/codec/responses_stream
import pig_protocol/error.{type AiError}
import pig_protocol/inference.{type InferenceResult}
import pig_protocol/message.{type Message}
import pig_protocol/sse
import pig_protocol/thinking.{type ThinkingLevel}
import pig_protocol/tool_definition.{type ToolDefinition}
import pig_transport
import pig_transport/hackney

/// The OpenAI API used for inference.
pub type OpenAIApi {
  ChatCompletions
  Responses
}

type OpenAIConfig {
  OpenAIConfig(
    api: OpenAIApi,
    api_key: String,
    model: String,
    base_url: String,
    http_timeout_ms: Int,
    default_thinking_level: Option(ThinkingLevel),
    transport: pig_transport.Transport,
  )
}

/// The default OpenAI base URL.
pub const default_base_url = "https://api.openai.com/v1"

/// The default HTTP timeout for OpenAI API calls (120 seconds).
pub const default_http_timeout_ms = 120_000

/// Create a streaming Chat Completions provider.
pub fn provider(api_key: String, model: String) -> provider.Provider {
  provider_with_base_url(api_key, model, default_base_url)
}

/// Create a streaming Chat Completions provider with a custom base URL.
pub fn provider_with_base_url(
  api_key: String,
  model: String,
  base_url: String,
) -> provider.Provider {
  provider_with_base_url_and_timeout(
    api_key,
    model,
    base_url,
    default_http_timeout_ms,
  )
}

/// Create a streaming Chat Completions provider with a custom timeout.
pub fn provider_with_base_url_and_timeout(
  api_key: String,
  model: String,
  base_url: String,
  http_timeout_ms: Int,
) -> provider.Provider {
  build_provider(OpenAIConfig(
    api: ChatCompletions,
    api_key:,
    model:,
    base_url:,
    http_timeout_ms:,
    default_thinking_level: None,
    transport: hackney.transport(),
  ))
}

/// Create a provider with a scripted or custom shared transport.
pub fn provider_with_transport(
  api: OpenAIApi,
  api_key: String,
  model: String,
  base_url: String,
  http_timeout_ms: Int,
  transport: pig_transport.Transport,
) -> provider.Provider {
  build_provider(OpenAIConfig(
    api:,
    api_key:,
    model:,
    base_url:,
    http_timeout_ms:,
    default_thinking_level: None,
    transport:,
  ))
}

/// Create a streaming Responses provider with the default OpenAI base URL.
pub fn responses_provider(api_key: String, model: String) -> provider.Provider {
  responses_provider_with_base_url(api_key, model, default_base_url)
}

/// Create a streaming Responses provider with a custom base URL.
pub fn responses_provider_with_base_url(
  api_key: String,
  model: String,
  base_url: String,
) -> provider.Provider {
  responses_provider_with_base_url_and_timeout(
    api_key,
    model,
    base_url,
    default_http_timeout_ms,
  )
}

/// Create a streaming Responses provider with a custom timeout.
pub fn responses_provider_with_base_url_and_timeout(
  api_key: String,
  model: String,
  base_url: String,
  http_timeout_ms: Int,
) -> provider.Provider {
  build_provider(OpenAIConfig(
    api: Responses,
    api_key:,
    model:,
    base_url:,
    http_timeout_ms:,
    default_thinking_level: None,
    transport: hackney.transport(),
  ))
}

/// Update an OpenAI-compatible provider's HTTP timeout.
pub fn with_http_timeout(
  openai_provider: provider.Provider,
  timeout_ms: Int,
) -> provider.Provider {
  provider.with_timeout(openai_provider, timeout_ms)
}

/// Set the fallback thinking level for calls made by this provider.
///
/// A request-level setting overrides this default.
pub fn with_default_thinking_level(
  openai_provider: provider.Provider,
  level: ThinkingLevel,
) -> provider.Provider {
  provider.with_default_thinking_level(openai_provider, level)
}

fn build_provider(config: OpenAIConfig) -> provider.Provider {
  provider.from_streaming_with_timeout(
    fn(request, emit) { do_stream(config, request, emit) },
    fn(timeout_ms) {
      build_provider(OpenAIConfig(..config, http_timeout_ms: timeout_ms))
    },
  )
}

/// Build the JSON request body for a streaming Chat Completions request.
/// Pure function - no IO.
pub fn build_request_body(
  messages: List(Message),
  tools: List(ToolDefinition),
  model: String,
) -> String {
  chat.build_stream_request_body(messages, tools, model)
}

/// Build a streaming Chat Completions request with a thinking level.
pub fn build_request_body_with_thinking(
  messages: List(Message),
  tools: List(ToolDefinition),
  model: String,
  thinking_level: Option(ThinkingLevel),
) -> String {
  chat.build_stream_request_body_with_thinking(
    messages,
    tools,
    model,
    thinking_level,
  )
}

/// Build a streaming Responses request body with a thinking level.
pub fn build_responses_request_body_with_thinking(
  messages: List(Message),
  tools: List(ToolDefinition),
  model: String,
  instructions: Option(String),
  thinking_level: Option(ThinkingLevel),
) -> String {
  responses.build_stream_request_body_with_thinking(
    messages,
    tools,
    model,
    instructions,
    thinking_level,
  )
}

/// Build a streaming Responses request body.
pub fn build_responses_request_body(
  messages: List(Message),
  tools: List(ToolDefinition),
  model: String,
  instructions: Option(String),
) -> String {
  responses.build_stream_request_body(messages, tools, model, instructions)
}

/// Parse an OpenAI Chat Completions JSON response into an InferenceResult.
/// Pure function - retained for callers handling captured non-stream data.
pub fn parse_response(raw: String) -> Result(InferenceResult, AiError) {
  chat.parse_response(raw)
}

fn do_stream(
  config: OpenAIConfig,
  request: provider.InferenceRequest,
  emit: fn(provider.InferenceEvent) -> Nil,
) -> Nil {
  let mode = auth.StandardApi(config.api_key, config.base_url)
  let body = request_body(config, request)
  let url = case config.api {
    ChatCompletions -> auth.chat_url(mode)
    Responses -> auth.responses_url(mode)
  }
  case auth.headers(mode, True) {
    Error(error) -> emit(provider.Finished(Error(error)))
    Ok(headers) -> {
      let request =
        pig_transport.Request(
          method: "POST",
          url:,
          headers:,
          body:,
          timeout_ms: config.http_timeout_ms,
        )
      let handle = pig_transport.open(config.transport, request)
      case config.api {
        ChatCompletions -> stream_chat(config.http_timeout_ms, handle, emit)
        Responses -> stream_responses(config.http_timeout_ms, handle, emit)
      }
    }
  }
}

fn request_body(
  config: OpenAIConfig,
  request: provider.InferenceRequest,
) -> String {
  let thinking_level = case request.settings.thinking {
    provider.UseProviderDefault -> config.default_thinking_level
    provider.UseThinkingLevel(level) -> Some(level)
  }
  case config.api {
    ChatCompletions ->
      chat.build_stream_request_body_with_thinking(
        request.messages,
        request.tools,
        config.model,
        thinking_level,
      )
    Responses ->
      responses.build_stream_request_body_with_thinking(
        request.messages,
        request.tools,
        config.model,
        instructions(request.messages),
        thinking_level,
      )
  }
}

fn instructions(messages: List(Message)) -> Option(String) {
  let system_messages =
    list.filter_map(messages, fn(part) {
      case part {
        message.System(content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
  case system_messages {
    [] -> None
    values -> Some(string.join(values, "\n\n"))
  }
}

fn stream_chat(
  timeout_ms: Int,
  handle: pig_transport.StreamHandle,
  emit: fn(provider.InferenceEvent) -> Nil,
) -> Nil {
  case pig_transport.receive(handle, timeout_ms) {
    Error(_) -> fail_stream(handle, emit, error.Timeout)
    Ok(pig_transport.Committed(..)) -> {
      let sink = process.new_subject()
      pig_transport.start(handle, sink)
      chat_loop(
        timeout_ms,
        handle,
        sink,
        emit,
        sse_decoder_new(),
        chat_stream.new(),
      )
    }
    Ok(pig_transport.Rejected(status:, body:, ..)) ->
      emit(provider.Finished(Error(rejected_error(status, body))))
    Ok(pig_transport.Failed(reason)) ->
      emit(provider.Finished(Error(transport_error(reason))))
    Ok(pig_transport.Cancelled) ->
      emit(provider.Finished(Error(error.Cancelled)))
    Ok(_) ->
      fail_stream(
        handle,
        emit,
        error.InvalidResponse("Transport committed an invalid stream state"),
      )
  }
}

fn stream_responses(
  timeout_ms: Int,
  handle: pig_transport.StreamHandle,
  emit: fn(provider.InferenceEvent) -> Nil,
) -> Nil {
  case pig_transport.receive(handle, timeout_ms) {
    Error(_) -> fail_stream(handle, emit, error.Timeout)
    Ok(pig_transport.Committed(..)) -> {
      let sink = process.new_subject()
      pig_transport.start(handle, sink)
      responses_loop(
        timeout_ms,
        handle,
        sink,
        emit,
        sse_decoder_new(),
        responses_stream.new(),
      )
    }
    Ok(pig_transport.Rejected(status:, body:, ..)) ->
      emit(provider.Finished(Error(rejected_error(status, body))))
    Ok(pig_transport.Failed(reason)) ->
      emit(provider.Finished(Error(transport_error(reason))))
    Ok(pig_transport.Cancelled) ->
      emit(provider.Finished(Error(error.Cancelled)))
    Ok(_) ->
      fail_stream(
        handle,
        emit,
        error.InvalidResponse("Transport committed an invalid stream state"),
      )
  }
}

fn sse_decoder_new() -> sse.Decoder {
  sse.new()
}

fn chat_loop(
  timeout_ms: Int,
  handle: pig_transport.StreamHandle,
  sink: process.Subject(pig_transport.Event),
  emit: fn(provider.InferenceEvent) -> Nil,
  decoder: sse.Decoder,
  accumulator: chat_stream.Accumulator,
) -> Nil {
  case process.receive(sink, timeout_ms) {
    Error(_) -> fail_stream(handle, emit, error.Timeout)
    Ok(pig_transport.Chunk(data)) ->
      case push_chat_bytes(decoder, accumulator, data, emit) {
        Ok(#(next_decoder, next_accumulator)) ->
          chat_loop(
            timeout_ms,
            handle,
            sink,
            emit,
            next_decoder,
            next_accumulator,
          )
        Error(reason) -> fail_stream(handle, emit, reason)
      }
    Ok(pig_transport.Done) -> {
      case finish_chat(decoder, accumulator, emit) {
        Ok(result) -> emit(provider.Finished(Ok(result)))
        Error(reason) -> emit(provider.Finished(Error(reason)))
      }
    }
    Ok(pig_transport.StreamError(reason)) ->
      fail_stream(handle, emit, transport_error(reason))
    Ok(pig_transport.Cancelled) ->
      emit(provider.Finished(Error(error.Cancelled)))
    Ok(_) ->
      fail_stream(handle, emit, error.InvalidResponse("Invalid stream event"))
  }
}

fn responses_loop(
  timeout_ms: Int,
  handle: pig_transport.StreamHandle,
  sink: process.Subject(pig_transport.Event),
  emit: fn(provider.InferenceEvent) -> Nil,
  decoder: sse.Decoder,
  accumulator: responses_stream.Accumulator,
) -> Nil {
  case process.receive(sink, timeout_ms) {
    Error(_) -> fail_stream(handle, emit, error.Timeout)
    Ok(pig_transport.Chunk(data)) ->
      case push_responses_bytes(decoder, accumulator, data, emit) {
        Ok(#(next_decoder, next_accumulator)) ->
          responses_loop(
            timeout_ms,
            handle,
            sink,
            emit,
            next_decoder,
            next_accumulator,
          )
        Error(reason) -> fail_stream(handle, emit, reason)
      }
    Ok(pig_transport.Done) -> {
      case finish_responses(decoder, accumulator, emit) {
        Ok(result) -> emit(provider.Finished(Ok(result)))
        Error(reason) -> emit(provider.Finished(Error(reason)))
      }
    }
    Ok(pig_transport.StreamError(reason)) ->
      fail_stream(handle, emit, transport_error(reason))
    Ok(pig_transport.Cancelled) ->
      emit(provider.Finished(Error(error.Cancelled)))
    Ok(_) ->
      fail_stream(handle, emit, error.InvalidResponse("Invalid stream event"))
  }
}

fn push_chat_bytes(
  decoder: sse.Decoder,
  accumulator: chat_stream.Accumulator,
  data: BitArray,
  emit: fn(provider.InferenceEvent) -> Nil,
) -> Result(#(sse.Decoder, chat_stream.Accumulator), AiError) {
  use #(next_decoder, frames) <- result.try(
    sse.push(decoder, data)
    |> result.map_error(fn(_) {
      error.InvalidResponse("SSE stream contained invalid UTF-8")
    }),
  )
  apply_chat_frames(next_decoder, accumulator, frames, emit)
}

fn apply_chat_frames(
  decoder: sse.Decoder,
  accumulator: chat_stream.Accumulator,
  frames: List(String),
  emit: fn(provider.InferenceEvent) -> Nil,
) -> Result(#(sse.Decoder, chat_stream.Accumulator), AiError) {
  list.fold(frames, Ok(#(decoder, accumulator)), fn(state_result, frame) {
    use #(current_decoder, current_accumulator) <- result.try(state_result)
    let payload = sse.frame_data(frame)
    case payload {
      "" -> Ok(#(current_decoder, current_accumulator))
      _ -> {
        use #(next, deltas) <- result.try(chat_stream.push(
          current_accumulator,
          payload,
        ))
        list.each(deltas, fn(delta) { emit(provider.Delta(delta)) })
        Ok(#(current_decoder, next))
      }
    }
  })
}

fn finish_chat(
  decoder: sse.Decoder,
  accumulator: chat_stream.Accumulator,
  emit: fn(provider.InferenceEvent) -> Nil,
) -> Result(InferenceResult, AiError) {
  use frames <- result.try(
    sse.finish(decoder)
    |> result.map_error(fn(_) {
      error.InvalidResponse("SSE stream contained invalid UTF-8")
    }),
  )
  use #(_decoder, next) <- result.try(apply_chat_frames(
    decoder,
    accumulator,
    frames,
    emit,
  ))
  chat_stream.finish(next)
}

fn push_responses_bytes(
  decoder: sse.Decoder,
  accumulator: responses_stream.Accumulator,
  data: BitArray,
  emit: fn(provider.InferenceEvent) -> Nil,
) -> Result(#(sse.Decoder, responses_stream.Accumulator), AiError) {
  use #(next_decoder, frames) <- result.try(
    sse.push(decoder, data)
    |> result.map_error(fn(_) {
      error.InvalidResponse("SSE stream contained invalid UTF-8")
    }),
  )
  apply_responses_frames(next_decoder, accumulator, frames, emit)
}

fn apply_responses_frames(
  decoder: sse.Decoder,
  accumulator: responses_stream.Accumulator,
  frames: List(String),
  emit: fn(provider.InferenceEvent) -> Nil,
) -> Result(#(sse.Decoder, responses_stream.Accumulator), AiError) {
  list.fold(frames, Ok(#(decoder, accumulator)), fn(state_result, frame) {
    use #(current_decoder, current_accumulator) <- result.try(state_result)
    let payload = sse.frame_data(frame)
    case payload {
      "" -> Ok(#(current_decoder, current_accumulator))
      _ -> {
        use #(next, deltas) <- result.try(responses_stream.push(
          current_accumulator,
          payload,
        ))
        list.each(deltas, fn(delta) { emit(provider.Delta(delta)) })
        Ok(#(current_decoder, next))
      }
    }
  })
}

fn finish_responses(
  decoder: sse.Decoder,
  accumulator: responses_stream.Accumulator,
  emit: fn(provider.InferenceEvent) -> Nil,
) -> Result(InferenceResult, AiError) {
  use frames <- result.try(
    sse.finish(decoder)
    |> result.map_error(fn(_) {
      error.InvalidResponse("SSE stream contained invalid UTF-8")
    }),
  )
  use #(_decoder, next) <- result.try(apply_responses_frames(
    decoder,
    accumulator,
    frames,
    emit,
  ))
  responses_stream.finish(next)
}

fn fail_stream(
  handle: pig_transport.StreamHandle,
  emit: fn(provider.InferenceEvent) -> Nil,
  reason: AiError,
) -> Nil {
  pig_transport.cancel(handle)
  emit(provider.Finished(Error(reason)))
}

fn rejected_error(status: Int, body: BitArray) -> AiError {
  let detail = case bit_array.to_string(body) {
    Ok(value) -> value
    Error(_) -> "<non-UTF-8 body>"
  }
  case status {
    429 -> error.RateLimited
    _ -> error.ApiError("HTTP " <> int_to_string(status) <> ": " <> detail)
  }
}

fn transport_error(reason: String) -> AiError {
  case string.contains(string.lowercase(reason), "timeout") {
    True -> error.Timeout
    False -> error.ApiError(reason)
  }
}

fn int_to_string(value: Int) -> String {
  int.to_string(value)
}
