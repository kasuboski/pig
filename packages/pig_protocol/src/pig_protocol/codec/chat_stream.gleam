//// Pure accumulator for Chat Completions SSE data payloads.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import pig_protocol/error.{type AiError}
import pig_protocol/inference.{
  type InferenceDelta, type InferenceResult, InferenceMetadata, InferenceResult,
  ReasoningDelta, TextDelta, ToolArgumentDelta, ToolCallStarted,
}
import pig_protocol/message
import pig_protocol/stop_reason

/// The pure state of a Chat Completions stream.
pub opaque type Accumulator {
  Accumulator(state: State)
}

type State {
  State(
    response_id: Option(String),
    response_model: Option(String),
    text: String,
    reasoning: String,
    tools: List(ToolState),
    stop_reason: Option(stop_reason.StopReason),
    input_tokens: Option(Int),
    output_tokens: Option(Int),
    cached_input_tokens: Option(Int),
    completion: Completion,
  )
}

type Completion {
  Open
  Done
}

type ToolState {
  ToolState(index: Int, id: String, name: String, arguments: String)
}

type Chunk {
  Chunk(
    response_id: Option(String),
    response_model: Option(String),
    choices: List(Choice),
    usage: Option(Usage),
  )
}

type Choice {
  Choice(delta: Delta, finish_reason: Option(String))
}

type Delta {
  Delta(text: Option(String), reasoning: Option(String), tools: List(ToolDelta))
}

type ToolDelta {
  ToolDelta(
    index: Int,
    id: Option(String),
    name: Option(String),
    arguments: Option(String),
  )
}

type Usage {
  Usage(input_tokens: Int, output_tokens: Int, cached_tokens: Option(Int))
}

/// Create an empty Chat Completions accumulator.
pub fn new() -> Accumulator {
  Accumulator(State(
    response_id: None,
    response_model: None,
    text: "",
    reasoning: "",
    tools: [],
    stop_reason: None,
    input_tokens: None,
    output_tokens: None,
    cached_input_tokens: None,
    completion: Open,
  ))
}

/// Apply one `data:` payload and return normalized deltas in provider order.
///
/// `[DONE]` is a terminal marker and produces no delta. JSON API errors and
/// malformed payloads are returned without mutating the accumulator.
pub fn push(
  accumulator: Accumulator,
  data: String,
) -> Result(#(Accumulator, List(InferenceDelta)), AiError) {
  let Accumulator(state) = accumulator
  case state.completion {
    Done -> Error(error.InvalidResponse("Event arrived after stream end"))
    Open -> {
      case string.trim(data) {
        "[DONE]" -> Ok(#(Accumulator(State(..state, completion: Done)), []))
        _ -> {
          use chunk <- result.try(parse_chunk(data))
          let #(next, deltas) = apply_chunk(state, chunk)
          Ok(#(Accumulator(next), deltas))
        }
      }
    }
  }
}

/// Finish a Chat Completions stream and build its normalized result.
///
/// A Chat Completions stream is complete only after `[DONE]`. This catches a
/// dropped connection that happened to arrive after a valid-looking chunk.
pub fn finish(accumulator: Accumulator) -> Result(InferenceResult, AiError) {
  let Accumulator(state) = accumulator
  case state.completion {
    Open -> Error(error.InvalidResponse("Stream ended before [DONE]"))
    Done -> Ok(to_result(state, state.stop_reason))
  }
}

fn parse_chunk(data: String) -> Result(Chunk, AiError) {
  case json.parse(from: data, using: api_error_decoder()) {
    Ok(message) if message != "" -> Error(error.ApiError(message))
    _ ->
      json.parse(from: data, using: chunk_decoder())
      |> result.map_error(fn(_) {
        error.InvalidResponse("Malformed Chat Completions stream event")
      })
  }
}

fn apply_chunk(state: State, chunk: Chunk) -> #(State, List(InferenceDelta)) {
  let next =
    State(
      ..state,
      response_id: first_value(state.response_id, chunk.response_id),
      response_model: first_value(state.response_model, chunk.response_model),
      input_tokens: usage_input(state.input_tokens, chunk.usage),
      output_tokens: usage_output(state.output_tokens, chunk.usage),
      cached_input_tokens: usage_cached(state.cached_input_tokens, chunk.usage),
    )
  list.fold(chunk.choices, #(next, []), apply_choice)
}

fn apply_choice(
  state: #(State, List(InferenceDelta)),
  choice: Choice,
) -> #(State, List(InferenceDelta)) {
  let #(current, deltas) = state
  let with_finish = case choice.finish_reason {
    Some(raw) ->
      State(..current, stop_reason: Some(stop_reason.from_openai(raw)))
    None -> current
  }
  let #(with_delta, new_deltas) = apply_delta(with_finish, choice.delta)
  #(with_delta, list.append(deltas, new_deltas))
}

fn apply_delta(state: State, delta: Delta) -> #(State, List(InferenceDelta)) {
  let #(with_text, text_deltas) = append_text(state, delta.text)
  let #(with_reasoning, reasoning_deltas) =
    append_reasoning(with_text, delta.reasoning)
  let #(with_tools, tool_deltas) =
    list.fold(delta.tools, #(with_reasoning, []), apply_tool)
  #(
    with_tools,
    list.append(list.append(text_deltas, reasoning_deltas), tool_deltas),
  )
}

fn append_text(
  state: State,
  value: Option(String),
) -> #(State, List(InferenceDelta)) {
  case value {
    Some(text) if text != "" -> #(State(..state, text: state.text <> text), [
      TextDelta(text),
    ])
    _ -> #(state, [])
  }
}

fn append_reasoning(
  state: State,
  value: Option(String),
) -> #(State, List(InferenceDelta)) {
  case value {
    Some(text) if text != "" -> #(
      State(..state, reasoning: state.reasoning <> text),
      [ReasoningDelta(text)],
    )
    _ -> #(state, [])
  }
}

fn apply_tool(
  state: #(State, List(InferenceDelta)),
  delta: ToolDelta,
) -> #(State, List(InferenceDelta)) {
  let #(current, emitted) = state
  case find_tool(delta.index, current.tools) {
    Error(Nil) -> {
      let id = option.unwrap(delta.id, "")
      let name = option.unwrap(delta.name, "")
      let arguments = option.unwrap(delta.arguments, "")
      let tool = ToolState(delta.index, id, name, arguments)
      let started = ToolCallStarted(delta.index, id, name)
      let args = case delta.arguments {
        Some(value) if value != "" -> [ToolArgumentDelta(delta.index, value)]
        _ -> []
      }
      let next = State(..current, tools: list.append(current.tools, [tool]))
      #(next, list.append(emitted, [started, ..args]))
    }
    Ok(existing) -> {
      let id =
        option.map(delta.id, fn(value) { merge_fragment(existing.id, value) })
      let name =
        option.map(delta.name, fn(value) {
          merge_fragment(existing.name, value)
        })
      let arguments = case delta.arguments {
        Some(value) -> existing.arguments <> value
        None -> existing.arguments
      }
      let updated =
        ToolState(
          index: existing.index,
          id: option.unwrap(id, existing.id),
          name: option.unwrap(name, existing.name),
          arguments: arguments,
        )
      let tools = replace_tool(updated, current.tools)
      let args = case delta.arguments {
        Some(value) if value != "" -> [ToolArgumentDelta(delta.index, value)]
        _ -> []
      }
      #(State(..current, tools: tools), list.append(emitted, args))
    }
  }
}

fn to_result(
  state: State,
  stop: Option(stop_reason.StopReason),
) -> InferenceResult {
  let thinking = case state.reasoning {
    "" -> None
    text -> Some(message.Thinking(text))
  }
  let tool_calls =
    list.map(state.tools, fn(tool) {
      message.ToolCall(
        id: tool.id,
        name: tool.name,
        arguments_json: tool.arguments,
      )
    })
  InferenceResult(
    message: message.Assistant(
      content: state.text,
      tool_calls: tool_calls,
      thinking: thinking,
      stop_reason: stop,
    ),
    metadata: InferenceMetadata(
      response_id: state.response_id,
      response_model: state.response_model,
      stop_reason: stop,
      input_tokens: state.input_tokens,
      output_tokens: state.output_tokens,
      cached_input_tokens: state.cached_input_tokens,
    ),
  )
}

fn find_tool(index: Int, tools: List(ToolState)) -> Result(ToolState, Nil) {
  list.find(tools, fn(tool) { tool.index == index })
}

fn replace_tool(updated: ToolState, tools: List(ToolState)) -> List(ToolState) {
  list.map(tools, fn(tool) {
    case tool.index == updated.index {
      True -> updated
      False -> tool
    }
  })
}

fn merge_fragment(current: String, incoming: String) -> String {
  case current {
    "" -> incoming
    _ ->
      case incoming == current {
        True -> current
        False ->
          case string.starts_with(incoming, current) {
            True -> incoming
            False ->
              case string.starts_with(current, incoming) {
                True -> current
                False -> current <> incoming
              }
          }
      }
  }
}

fn first_value(
  current: Option(String),
  next: Option(String),
) -> Option(String) {
  case current {
    Some(_) -> current
    None -> next
  }
}

fn usage_input(current: Option(Int), usage: Option(Usage)) -> Option(Int) {
  case usage {
    Some(value) -> Some(value.input_tokens)
    None -> current
  }
}

fn usage_output(current: Option(Int), usage: Option(Usage)) -> Option(Int) {
  case usage {
    Some(value) -> Some(value.output_tokens)
    None -> current
  }
}

fn usage_cached(current: Option(Int), usage: Option(Usage)) -> Option(Int) {
  case usage {
    Some(value) -> value.cached_tokens
    None -> current
  }
}

fn api_error_decoder() -> decode.Decoder(String) {
  use message <- decode.subfield(["error", "message"], decode.string)
  decode.success(message)
}

fn chunk_decoder() -> decode.Decoder(Chunk) {
  use response_id <- decode.optional_field(
    "id",
    None,
    decode.optional(decode.string),
  )
  use response_model <- decode.optional_field(
    "model",
    None,
    decode.optional(decode.string),
  )
  use choices <- decode.field("choices", decode.list(choice_decoder()))
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(usage_decoder()),
  )
  decode.success(Chunk(response_id:, response_model:, choices:, usage:))
}

fn choice_decoder() -> decode.Decoder(Choice) {
  use delta <- decode.optional_field("delta", empty_delta(), delta_decoder())
  use finish_reason <- decode.optional_field(
    "finish_reason",
    None,
    decode.optional(decode.string),
  )
  decode.success(Choice(delta:, finish_reason:))
}

fn empty_delta() -> Delta {
  Delta(text: None, reasoning: None, tools: [])
}

fn delta_decoder() -> decode.Decoder(Delta) {
  use text <- decode.optional_field(
    "content",
    None,
    decode.optional(decode.string),
  )
  use reasoning_content <- decode.optional_field(
    "reasoning_content",
    None,
    decode.optional(decode.string),
  )
  use reasoning <- decode.optional_field(
    "reasoning",
    None,
    decode.optional(decode.string),
  )
  use reasoning_text <- decode.optional_field(
    "reasoning_text",
    None,
    decode.optional(decode.string),
  )
  use tools <- decode.optional_field(
    "tool_calls",
    None,
    decode.optional(decode.list(tool_delta_decoder())),
  )
  decode.success(Delta(
    text: text,
    reasoning: first_non_empty([reasoning_content, reasoning, reasoning_text]),
    tools: option.unwrap(tools, []),
  ))
}

fn first_non_empty(values: List(Option(String))) -> Option(String) {
  case values {
    [] -> None
    [Some(value), ..] if value != "" -> Some(value)
    [_first, ..rest] -> first_non_empty(rest)
  }
}

fn tool_delta_decoder() -> decode.Decoder(ToolDelta) {
  use index <- decode.field("index", decode.int)
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  use function <- decode.optional_field(
    "function",
    None,
    decode.optional(function_delta_decoder()),
  )
  let #(name, arguments) = case function {
    Some(value) -> #(value.name, value.arguments)
    None -> #(None, None)
  }
  decode.success(ToolDelta(index:, id:, name:, arguments:))
}

type FunctionDelta {
  FunctionDelta(name: Option(String), arguments: Option(String))
}

fn function_delta_decoder() -> decode.Decoder(FunctionDelta) {
  use name <- decode.optional_field(
    "name",
    None,
    decode.optional(decode.string),
  )
  use arguments <- decode.optional_field(
    "arguments",
    None,
    decode.optional(decode.string),
  )
  decode.success(FunctionDelta(name:, arguments:))
}

fn usage_decoder() -> decode.Decoder(Usage) {
  use input_tokens <- decode.field("prompt_tokens", decode.int)
  use output_tokens <- decode.field("completion_tokens", decode.int)
  use cached_tokens <- decode.optional_field(
    "prompt_tokens_details",
    None,
    cached_tokens_details_decoder(),
  )
  decode.success(Usage(input_tokens:, output_tokens:, cached_tokens:))
}

/// OpenAI nests cached input tokens under `prompt_tokens_details`.
fn cached_tokens_details_decoder() -> decode.Decoder(Option(Int)) {
  use cached_tokens <- decode.optional_field(
    "cached_tokens",
    None,
    decode.optional(decode.int),
  )
  decode.success(cached_tokens)
}
