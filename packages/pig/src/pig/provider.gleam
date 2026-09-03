//// Streaming-first provider boundary for `pig`.
////
//// A Provider owns how an inference is started; an Inference owns its
//// cancellable event stream. The coordinator below is the only layer that
//// decides inference terminality, so exactly one `Finished` event crosses the
//// boundary even when a source races cancellation or emits late events.

import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import pig_protocol/error.{type AiError}
import pig_protocol/inference.{type InferenceDelta}
import pig_protocol/message.{type Message}
import pig_protocol/stop_reason.{type StopReason}
import pig_protocol/thinking
import pig_protocol/tool_definition.{type ToolDefinition}

/// The thinking configuration for one inference request.
pub type ThinkingSetting {
  UseProviderDefault
  UseThinkingLevel(thinking.ThinkingLevel)
}

/// Inference settings passed to a provider.
pub type InferenceSettings {
  InferenceSettings(thinking: ThinkingSetting)
}

/// The messages, tools, and settings for one provider call.
pub type InferenceRequest {
  InferenceRequest(
    messages: List(Message),
    tools: List(ToolDefinition),
    settings: InferenceSettings,
  )
}

/// Events emitted by an inference. `Finished` is emitted exactly once.
pub type InferenceEvent {
  Delta(InferenceDelta)
  Finished(Result(InferenceResult, AiError))
}

/// An opaque provider that starts asynchronous inference work.
pub opaque type Provider {
  Provider(
    start: fn(InferenceRequest, fn(InferenceEvent) -> Nil) -> Nil,
    default_thinking_level: Option(thinking.ThinkingLevel),
    update_timeout: fn(Int) -> Provider,
  )
}

/// An opaque, cancellable inference handle.
pub opaque type Inference {
  Inference(
    events: process.Subject(InferenceEvent),
    terminal: process.Subject(Terminal),
    commands: process.Subject(Command),
  )
}

type Terminal {
  Terminal(Result(InferenceResult, AiError))
}

type Command {
  Cancel
}

type CoordinatorMessage {
  Source(InferenceEvent)
  SourceEnded
  SourceDown
  OwnerDown
  CancelRequested
}

type CoordinatorState {
  CoordinatorState(
    events: process.Subject(InferenceEvent),
    terminal: process.Subject(Terminal),
    commands: process.Subject(Command),
    source_events: process.Subject(CoordinatorMessage),
    source: process.Pid,
    owner: process.Pid,
    source_monitor: process.Monitor,
    owner_monitor: process.Monitor,
  )
}

type CollectMessage {
  TerminalEvent(Result(InferenceResult, AiError))
  Deadline
}

/// Return settings that defer thinking configuration to the provider.
pub fn default_settings() -> InferenceSettings {
  InferenceSettings(thinking: UseProviderDefault)
}

/// Return settings requesting the given thinking level.
pub fn with_thinking_level(level: thinking.ThinkingLevel) -> InferenceSettings {
  InferenceSettings(thinking: UseThinkingLevel(level))
}

/// Encode inference settings using the stable provider-neutral representation.
pub fn settings_to_string(settings: InferenceSettings) -> String {
  case settings {
    InferenceSettings(thinking: UseProviderDefault) -> "provider_default"
    InferenceSettings(thinking: UseThinkingLevel(level)) ->
      thinking.to_string(level)
  }
}

/// Decode the stable provider-neutral representation of inference settings.
pub fn settings_from_string(value: String) -> Result(InferenceSettings, Nil) {
  case value {
    "provider_default" -> Ok(default_settings())
    _ ->
      case thinking.from_string(value) {
        Ok(level) -> Ok(with_thinking_level(level))
        Error(Nil) -> Error(Nil)
      }
  }
}

/// Result of a provider call - the message plus metadata from the API response.
pub type InferenceResult =
  inference.InferenceResult

/// Metadata returned by the provider alongside the message.
pub type InferenceMetadata =
  inference.InferenceMetadata

/// Build a provider from a source that may emit normalized events.
pub fn from_streaming(
  start: fn(InferenceRequest, fn(InferenceEvent) -> Nil) -> Nil,
) -> Provider {
  Provider(start:, default_thinking_level: None, update_timeout: fn(_timeout) {
    from_streaming(start)
  })
}

/// Build a provider with a provider-specific timeout update.
pub fn from_streaming_with_timeout(
  start: fn(InferenceRequest, fn(InferenceEvent) -> Nil) -> Nil,
  update_timeout: fn(Int) -> Provider,
) -> Provider {
  Provider(start:, default_thinking_level: None, update_timeout:)
}

/// Set the provider fallback thinking level. Request-level settings still win.
pub fn with_default_thinking_level(
  provider: Provider,
  level: thinking.ThinkingLevel,
) -> Provider {
  Provider(..provider, default_thinking_level: Some(level))
}

/// Apply a provider-specific HTTP timeout when the provider supports it.
pub fn with_timeout(provider: Provider, timeout_ms: Int) -> Provider {
  let Provider(default_thinking_level:, update_timeout:, ..) = provider
  let updated = update_timeout(timeout_ms)
  Provider(..updated, default_thinking_level:)
}

/// Build a provider from the existing buffered provider shape.
pub fn from_buffered(
  call: fn(InferenceRequest) -> Result(InferenceResult, AiError),
) -> Provider {
  from_streaming(fn(request, emit) { emit(Finished(call(request))) })
}

/// Start inference and return immediately with an opaque handle.
pub fn start(provider: Provider, request: InferenceRequest) -> Inference {
  let Provider(start:, default_thinking_level:, ..) = provider
  let request = apply_default_thinking(request, default_thinking_level)
  let events = process.new_subject()
  let terminal = process.new_subject()
  let ready = process.new_subject()
  let owner = process.self()
  let _ =
    process.spawn_unlinked(fn() {
      let commands = process.new_subject()
      let source_events = process.new_subject()
      process.send(ready, commands)
      let source =
        process.spawn_unlinked(fn() {
          start(request, fn(event) {
            process.send(source_events, Source(event))
          })
          process.send(source_events, SourceEnded)
          hold_until_released()
        })
      let state =
        CoordinatorState(
          events:,
          terminal:,
          commands:,
          source_events:,
          source:,
          owner:,
          source_monitor: process.monitor(source),
          owner_monitor: process.monitor(owner),
        )
      coordinator_loop(state)
    })
  let commands = process.receive_forever(ready)
  Inference(events:, terminal:, commands:)
}

fn hold_until_released() -> Nil {
  let release = process.new_subject()
  process.receive_forever(release)
}

fn apply_default_thinking(
  request: InferenceRequest,
  default_level: Option(thinking.ThinkingLevel),
) -> InferenceRequest {
  case request.settings.thinking, default_level {
    UseProviderDefault, Some(level) ->
      InferenceRequest(..request, settings: with_thinking_level(level))
    _, _ -> request
  }
}

/// Receive the next inference event from its handle.
pub fn receive(
  inference: Inference,
  timeout_ms: Int,
) -> Result(InferenceEvent, Nil) {
  process.receive(inference.events, timeout_ms)
}

@internal
pub fn receive_forever(inference: Inference) -> InferenceEvent {
  process.receive_forever(inference.events)
}

/// Cancel an inference. Repeated cancellation is harmless.
pub fn cancel(inference: Inference) -> Nil {
  process.send(inference.commands, Cancel)
}

/// Collect an inference for transitional synchronous callers. Timeout cancels.
pub fn collect(
  inference: Inference,
  timeout_ms: Int,
) -> Result(InferenceResult, AiError) {
  let deadline = process.new_subject()
  let timer = process.send_after(deadline, timeout_ms, Nil)
  let selector =
    process.new_selector()
    |> process.select_map(inference.terminal, fn(terminal) {
      let Terminal(result) = terminal
      TerminalEvent(result)
    })
    |> process.select_map(deadline, fn(_) { Deadline })
  collect_events(inference, selector, timer)
}

fn collect_events(
  inference: Inference,
  selector: process.Selector(CollectMessage),
  timer: process.Timer,
) -> Result(InferenceResult, AiError) {
  case process.selector_receive_forever(selector) {
    TerminalEvent(result) -> {
      let _ = process.cancel_timer(timer)
      result
    }
    Deadline ->
      case process.receive(inference.terminal, 0) {
        Ok(Terminal(result)) -> {
          let _ = process.cancel_timer(timer)
          result
        }
        Error(Nil) -> {
          cancel(inference)
          Error(error.Timeout)
        }
      }
  }
}

/// Start and collect one inference for transitional synchronous callers.
pub fn run(
  provider: Provider,
  request: InferenceRequest,
  timeout_ms: Int,
) -> Result(InferenceResult, AiError) {
  start(provider, request) |> collect(timeout_ms)
}

fn coordinator_loop(state: CoordinatorState) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(state.source_events, fn(message) { message })
    |> process.select_map(state.commands, fn(command) {
      case command {
        Cancel -> CancelRequested
      }
    })
    |> process.select_specific_monitor(state.source_monitor, fn(_) {
      SourceDown
    })
    |> process.select_specific_monitor(state.owner_monitor, fn(_) { OwnerDown })
  case process.selector_receive_forever(selector) {
    Source(event) ->
      case process.is_alive(state.owner) {
        True -> handle_source_event(state, event)
        False -> finish_if_open(state, error.Cancelled)
      }
    SourceEnded ->
      case process.is_alive(state.owner) {
        True ->
          finish_if_open(
            state,
            error.InvalidResponse("Provider ended without a terminal event"),
          )
        False -> finish_if_open(state, error.Cancelled)
      }
    SourceDown ->
      case process.is_alive(state.owner) {
        True ->
          finish_if_open(
            state,
            error.InvalidResponse(
              "Provider process exited without a terminal event",
            ),
          )
        False -> finish_if_open(state, error.Cancelled)
      }
    OwnerDown -> finish_if_open(state, error.Cancelled)
    CancelRequested -> {
      process.kill(state.source)
      send_finished(state, Error(error.Cancelled))
    }
  }
}

fn handle_source_event(state: CoordinatorState, event: InferenceEvent) -> Nil {
  case event {
    Delta(delta) -> {
      process.send(state.events, Delta(delta))
      coordinator_loop(state)
    }
    Finished(result) -> send_finished(state, result)
  }
}

fn finish_if_open(state: CoordinatorState, reason: AiError) -> Nil {
  send_finished(state, Error(reason))
}

fn send_finished(
  state: CoordinatorState,
  result: Result(InferenceResult, AiError),
) -> Nil {
  process.kill(state.source)
  process.send(state.terminal, Terminal(result))
  process.send(state.events, Finished(result))
}

/// Create an InferenceMetadata with all fields set to None.
pub fn default_metadata() -> InferenceMetadata {
  inference.default_metadata()
}

/// Wrap a bare Message into an InferenceResult with default metadata.
pub fn from_message(msg: Message) -> InferenceResult {
  inference.from_message(msg)
}

/// Set response_id on metadata.
pub fn with_response_id(
  meta: InferenceMetadata,
  id: String,
) -> InferenceMetadata {
  inference.with_response_id(meta, id)
}

/// Set response_model on metadata.
pub fn with_response_model(
  meta: InferenceMetadata,
  model: String,
) -> InferenceMetadata {
  inference.with_response_model(meta, model)
}

/// Set stop_reason on metadata.
pub fn with_stop_reason(
  meta: InferenceMetadata,
  reason: StopReason,
) -> InferenceMetadata {
  inference.with_stop_reason(meta, reason)
}

/// Set input_tokens on metadata.
pub fn with_input_tokens(
  meta: InferenceMetadata,
  tokens: Int,
) -> InferenceMetadata {
  inference.with_input_tokens(meta, tokens)
}

/// Set output_tokens on metadata.
pub fn with_output_tokens(
  meta: InferenceMetadata,
  tokens: Int,
) -> InferenceMetadata {
  inference.with_output_tokens(meta, tokens)
}

/// Set cached_input_tokens on metadata.
pub fn with_cached_input_tokens(
  meta: InferenceMetadata,
  tokens: Int,
) -> InferenceMetadata {
  inference.with_cached_input_tokens(meta, tokens)
}
