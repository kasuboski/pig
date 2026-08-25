//// Pure accumulator for OpenAI Responses SSE event payloads.

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

/// The pure state of a Responses stream.
pub opaque type Accumulator {
  Accumulator(state: State)
}

type State {
  State(
    response_id: Option(String),
    response_model: Option(String),
    text: String,
    reasoning: String,
    slots: List(Slot),
    terminal: Option(Terminal),
  )
}

type Slot {
  TextSlot(index: Int, text: String)
  ReasoningSlot(index: Int, text: String)
  ToolSlot(index: Int, id: String, name: String, arguments: String)
}

type Terminal {
  Terminal(
    response_id: Option(String),
    response_model: Option(String),
    stop_reason: stop_reason.StopReason,
    input_tokens: Option(Int),
    output_tokens: Option(Int),
  )
}

type Event {
  Created(response_id: String, response_model: Option(String))
  OutputAdded(index: Int, item: OutputItem)
  Text(index: Int, delta: String)
  Refusal(index: Int, delta: String)
  Reasoning(index: Int, delta: String)
  ReasoningPartDone(index: Int)
  Arguments(index: Int, delta: String)
  ArgumentsDone(index: Int, arguments: String)
  OutputDone(index: Int, item: OutputItem)
  Completed(terminal: Terminal)
  Incomplete(terminal: Terminal)
  Failed(message: String)
  ProviderError(message: String)
  Unsupported
}

type OutputItem {
  MessageItem(text: String)
  ReasoningItem(summary: String, content: String)
  FunctionItem(id: String, name: String, arguments: String)
  OtherItem
}

type ContentBlock {
  TextBlock(text: String)
  RefusalBlock(text: String)
  OtherBlock
}

/// Create an empty Responses accumulator.
pub fn new() -> Accumulator {
  Accumulator(State(
    response_id: None,
    response_model: None,
    text: "",
    reasoning: "",
    slots: [],
    terminal: None,
  ))
}

/// Apply one Responses SSE `data:` payload and return normalized deltas.
///
/// Unknown provider event types are ignored. Malformed supported events and
/// provider error events are returned as normalized `AiError` values.
pub fn push(
  accumulator: Accumulator,
  data: String,
) -> Result(#(Accumulator, List(InferenceDelta)), AiError) {
  let Accumulator(state) = accumulator
  case state.terminal {
    Some(_) -> Error(error.InvalidResponse("Event arrived after stream end"))
    None -> {
      use event <- result.try(parse_event(data))
      use #(next, deltas) <- result.try(apply_event(state, event))
      Ok(#(Accumulator(next), deltas))
    }
  }
}

/// Finish a Responses stream and build its normalized result.
///
/// A terminal response event is mandatory. This distinguishes a provider
/// response that completed from a connection that ended early.
pub fn finish(accumulator: Accumulator) -> Result(InferenceResult, AiError) {
  let Accumulator(state) = accumulator
  case state.terminal {
    None ->
      Error(error.InvalidResponse(
        "Stream ended before a terminal Responses event",
      ))
    Some(terminal) -> {
      let stop = case has_tool(state.slots) {
        True -> stop_reason.ToolUse
        False -> terminal.stop_reason
      }
      let thinking = case state.reasoning {
        "" -> None
        text -> Some(message.Thinking(text))
      }
      let tools = state.slots |> list.filter_map(tool_from_slot)
      Ok(InferenceResult(
        message: message.Assistant(
          content: state.text,
          tool_calls: tools,
          thinking: thinking,
          stop_reason: Some(stop),
        ),
        metadata: InferenceMetadata(
          response_id: first_value(terminal.response_id, state.response_id),
          response_model: first_value(
            terminal.response_model,
            state.response_model,
          ),
          stop_reason: Some(stop),
          input_tokens: terminal.input_tokens,
          output_tokens: terminal.output_tokens,
        ),
      ))
    }
  }
}

fn parse_event(data: String) -> Result(Event, AiError) {
  json.parse(from: data, using: event_decoder())
  |> result.map_error(fn(_) {
    error.InvalidResponse("Malformed Responses stream event")
  })
}

fn apply_event(
  state: State,
  event: Event,
) -> Result(#(State, List(InferenceDelta)), AiError) {
  case event {
    Created(response_id, response_model) ->
      Ok(
        #(
          State(
            ..state,
            response_id: Some(response_id),
            response_model: first_value(state.response_model, response_model),
          ),
          [],
        ),
      )

    OutputAdded(index, item) -> add_output_item(state, index, item)
    Text(index, delta) -> append_text_slot(state, index, delta)
    Refusal(index, delta) -> append_text_slot(state, index, delta)
    Reasoning(index, delta) -> append_reasoning_slot(state, index, delta)
    ReasoningPartDone(index) -> append_reasoning_slot(state, index, "\n\n")
    Arguments(index, delta) -> append_argument_slot(state, index, delta)
    ArgumentsDone(index, arguments) -> finish_arguments(state, index, arguments)
    OutputDone(index, item) -> finish_output_item(state, index, item)
    Completed(terminal) -> Ok(#(State(..state, terminal: Some(terminal)), []))
    Incomplete(terminal) -> Ok(#(State(..state, terminal: Some(terminal)), []))
    Failed(message) -> Error(error.ApiError(message))
    ProviderError(message) -> Error(error.ApiError(message))
    Unsupported -> Ok(#(state, []))
  }
}

fn add_output_item(
  state: State,
  index: Int,
  item: OutputItem,
) -> Result(#(State, List(InferenceDelta)), AiError) {
  case item {
    FunctionItem(id, name, _) -> {
      case find_slot(index, state.slots) {
        Ok(_) -> Ok(#(state, []))
        Error(Nil) -> {
          let slot = ToolSlot(index, id, name, "")
          Ok(
            #(State(..state, slots: list.append(state.slots, [slot])), [
              ToolCallStarted(index, id, name),
            ]),
          )
        }
      }
    }
    MessageItem(_) -> add_empty_slot(state, index, TextSlot(index, ""))
    ReasoningItem(_, _) ->
      add_empty_slot(state, index, ReasoningSlot(index, ""))
    OtherItem -> Ok(#(state, []))
  }
}

fn add_empty_slot(
  state: State,
  index: Int,
  slot: Slot,
) -> Result(#(State, List(InferenceDelta)), AiError) {
  case find_slot(index, state.slots) {
    Ok(_) -> Ok(#(state, []))
    Error(Nil) ->
      Ok(#(State(..state, slots: list.append(state.slots, [slot])), []))
  }
}

fn append_text_slot(
  state: State,
  index: Int,
  delta: String,
) -> Result(#(State, List(InferenceDelta)), AiError) {
  case find_slot(index, state.slots) {
    Ok(TextSlot(_, text)) -> {
      let next = replace_slot(TextSlot(index, text <> delta), state.slots)
      Ok(
        #(State(..state, text: state.text <> delta, slots: next), [
          TextDelta(delta),
        ]),
      )
    }
    Error(Nil) -> {
      let slot = TextSlot(index, delta)
      Ok(
        #(
          State(
            ..state,
            text: state.text <> delta,
            slots: append_slot(slot, state.slots),
          ),
          [TextDelta(delta)],
        ),
      )
    }
    Ok(_) -> Error(error.InvalidResponse("Output index is not a text item"))
  }
}

fn append_reasoning_slot(
  state: State,
  index: Int,
  delta: String,
) -> Result(#(State, List(InferenceDelta)), AiError) {
  case find_slot(index, state.slots) {
    Ok(ReasoningSlot(_, text)) -> {
      let next = replace_slot(ReasoningSlot(index, text <> delta), state.slots)
      Ok(
        #(State(..state, reasoning: state.reasoning <> delta, slots: next), [
          ReasoningDelta(delta),
        ]),
      )
    }
    Error(Nil) -> {
      let slot = ReasoningSlot(index, delta)
      Ok(
        #(
          State(
            ..state,
            reasoning: state.reasoning <> delta,
            slots: append_slot(slot, state.slots),
          ),
          [ReasoningDelta(delta)],
        ),
      )
    }
    Ok(_) ->
      Error(error.InvalidResponse("Output index is not a reasoning item"))
  }
}

fn append_argument_slot(
  state: State,
  index: Int,
  delta: String,
) -> Result(#(State, List(InferenceDelta)), AiError) {
  case find_slot(index, state.slots) {
    Ok(ToolSlot(_, id, name, arguments)) -> {
      let slot = ToolSlot(index, id, name, arguments <> delta)
      Ok(
        #(State(..state, slots: replace_slot(slot, state.slots)), [
          ToolArgumentDelta(index, delta),
        ]),
      )
    }
    _ ->
      Error(error.InvalidResponse("Arguments arrived before a function call"))
  }
}

fn finish_arguments(
  state: State,
  index: Int,
  arguments: String,
) -> Result(#(State, List(InferenceDelta)), AiError) {
  case find_slot(index, state.slots) {
    Ok(ToolSlot(_, id, name, previous)) -> {
      let #(final_arguments, suffix) = suffix_delta(previous, arguments)
      let slot = ToolSlot(index, id, name, final_arguments)
      let deltas = case suffix {
        "" -> []
        value -> [ToolArgumentDelta(index, value)]
      }
      Ok(#(State(..state, slots: replace_slot(slot, state.slots)), deltas))
    }
    _ ->
      Error(error.InvalidResponse("Arguments completed before a function call"))
  }
}

fn finish_output_item(
  state: State,
  index: Int,
  item: OutputItem,
) -> Result(#(State, List(InferenceDelta)), AiError) {
  case item {
    MessageItem(text) -> finish_text_item(state, index, text)
    ReasoningItem(summary, content) ->
      finish_reasoning_item(state, index, first_non_empty(summary, content))
    FunctionItem(id, name, arguments) -> {
      let with_slot = case find_slot(index, state.slots) {
        Ok(_) -> state
        Error(Nil) -> {
          let slot = ToolSlot(index, id, name, "")
          State(..state, slots: append_slot(slot, state.slots))
        }
      }
      let started = case find_slot(index, state.slots) {
        Ok(_) -> []
        Error(Nil) -> [ToolCallStarted(index, id, name)]
      }
      case finish_arguments(with_slot, index, arguments) {
        Ok(#(next, deltas)) -> Ok(#(next, list.append(started, deltas)))
        Error(reason) -> Error(reason)
      }
    }
    OtherItem -> Ok(#(state, []))
  }
}

fn finish_text_item(
  state: State,
  index: Int,
  text: String,
) -> Result(#(State, List(InferenceDelta)), AiError) {
  case find_slot(index, state.slots) {
    Ok(TextSlot(_, current)) if current != "" -> Ok(#(state, []))
    Ok(TextSlot(_, _)) -> append_text_slot(state, index, text)
    Error(Nil) -> append_text_slot(state, index, text)
    Ok(_) -> Error(error.InvalidResponse("Output index is not a text item"))
  }
}

fn finish_reasoning_item(
  state: State,
  index: Int,
  text: String,
) -> Result(#(State, List(InferenceDelta)), AiError) {
  case find_slot(index, state.slots) {
    Ok(ReasoningSlot(_, _)) -> {
      let slots = replace_slot(ReasoningSlot(index, text), state.slots)
      Ok(
        #(
          State(..state, reasoning: reasoning_from_slots(slots), slots: slots),
          [],
        ),
      )
    }
    Error(Nil) -> append_reasoning_slot(state, index, text)
    Ok(_) ->
      Error(error.InvalidResponse("Output index is not a reasoning item"))
  }
}

fn reasoning_from_slots(slots: List(Slot)) -> String {
  slots
  |> list.filter_map(fn(slot) {
    case slot {
      ReasoningSlot(_, text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.join("")
}

fn suffix_delta(previous: String, final: String) -> #(String, String) {
  case final == previous {
    True -> #(final, "")
    False ->
      case string.starts_with(final, previous) {
        True -> #(final, string.drop_start(final, string.length(previous)))
        False -> #(final, "")
      }
  }
}

fn first_non_empty(first: String, second: String) -> String {
  case first {
    "" -> second
    _ -> first
  }
}

fn find_slot(index: Int, slots: List(Slot)) -> Result(Slot, Nil) {
  list.find(slots, fn(slot) { slot_index(slot) == index })
}

fn slot_index(slot: Slot) -> Int {
  case slot {
    TextSlot(index, _) -> index
    ReasoningSlot(index, _) -> index
    ToolSlot(index, _, _, _) -> index
  }
}

fn append_slot(slot: Slot, slots: List(Slot)) -> List(Slot) {
  list.append(slots, [slot])
}

fn replace_slot(updated: Slot, slots: List(Slot)) -> List(Slot) {
  list.map(slots, fn(slot) {
    case slot_index(slot) == slot_index(updated) {
      True -> updated
      False -> slot
    }
  })
}

fn tool_from_slot(slot: Slot) -> Result(message.ToolCall, Nil) {
  case slot {
    ToolSlot(_, id, name, arguments) ->
      Ok(message.ToolCall(id: id, name: name, arguments_json: arguments))
    _ -> Error(Nil)
  }
}

fn has_tool(slots: List(Slot)) -> Bool {
  list.any(slots, fn(slot) {
    case slot {
      ToolSlot(_, _, _, _) -> True
      _ -> False
    }
  })
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

fn event_decoder() -> decode.Decoder(Event) {
  use event_type <- decode.field("type", decode.string)
  case event_type {
    "response.created" -> {
      use created <- decode.subfield(["response"], created_decoder())
      decode.success(Created(created.id, created.model))
    }
    "response.output_item.added" -> {
      use index <- decode.field("output_index", decode.int)
      use item <- decode.field("item", output_item_decoder())
      decode.success(OutputAdded(index, item))
    }
    "response.output_text.delta" -> delta_event_decoder(Text)
    "response.refusal.delta" -> delta_event_decoder(Refusal)
    "response.reasoning_summary_text.delta" -> delta_event_decoder(Reasoning)
    "response.reasoning_text.delta" -> delta_event_decoder(Reasoning)
    "response.reasoning_summary_part.done" -> {
      use index <- decode.field("output_index", decode.int)
      decode.success(ReasoningPartDone(index))
    }
    "response.function_call_arguments.delta" -> {
      use index <- decode.field("output_index", decode.int)
      use delta <- decode.field("delta", decode.string)
      decode.success(Arguments(index, delta))
    }
    "response.function_call_arguments.done" -> {
      use index <- decode.field("output_index", decode.int)
      use arguments <- decode.field("arguments", decode.string)
      decode.success(ArgumentsDone(index, arguments))
    }
    "response.output_item.done" -> {
      use index <- decode.field("output_index", decode.int)
      use item <- decode.field("item", output_item_decoder())
      decode.success(OutputDone(index, item))
    }
    "response.completed" -> decode.map(terminal_event_decoder(), Completed)
    "response.incomplete" -> decode.map(terminal_event_decoder(), Incomplete)
    "response.failed" -> decode.map(failed_event_decoder(), Failed)
    "error" -> decode.map(error_event_decoder(), ProviderError)
    _ -> decode.success(Unsupported)
  }
}

fn delta_event_decoder(
  constructor: fn(Int, String) -> Event,
) -> decode.Decoder(Event) {
  use index <- decode.field("output_index", decode.int)
  use delta <- decode.field("delta", decode.string)
  decode.success(constructor(index, delta))
}

type CreatedResponse {
  CreatedResponse(id: String, model: Option(String))
}

fn created_decoder() -> decode.Decoder(CreatedResponse) {
  use id <- decode.field("id", decode.string)
  use model <- decode.optional_field(
    "model",
    None,
    decode.optional(decode.string),
  )
  decode.success(CreatedResponse(id:, model:))
}

fn output_item_decoder() -> decode.Decoder(OutputItem) {
  use item_type <- decode.field("type", decode.string)
  case item_type {
    "message" -> {
      use content <- decode.optional_field(
        "content",
        None,
        decode.optional(decode.list(content_block_decoder())),
      )
      decode.success(MessageItem(content_text(option.unwrap(content, []))))
    }
    "reasoning" -> {
      use summary <- decode.optional_field(
        "summary",
        None,
        decode.optional(decode.list(reasoning_block_decoder())),
      )
      use content <- decode.optional_field(
        "content",
        None,
        decode.optional(decode.list(reasoning_block_decoder())),
      )
      decode.success(ReasoningItem(
        summary: block_text(option.unwrap(summary, [])),
        content: block_text(option.unwrap(content, [])),
      ))
    }
    "function_call" -> {
      use id <- decode.optional_field("call_id", "", decode.string)
      use fallback_id <- decode.optional_field("id", "", decode.string)
      use name <- decode.optional_field("name", "", decode.string)
      use arguments <- decode.optional_field("arguments", "", decode.string)
      let call_id = case id {
        "" -> fallback_id
        _ -> id
      }
      decode.success(FunctionItem(call_id, name, arguments))
    }
    _ -> decode.success(OtherItem)
  }
}

fn content_block_decoder() -> decode.Decoder(ContentBlock) {
  use block_type <- decode.field("type", decode.string)
  case block_type {
    "output_text" -> text_block_decoder()
    "refusal" -> refusal_block_decoder()
    _ -> decode.success(OtherBlock)
  }
}

fn text_block_decoder() -> decode.Decoder(ContentBlock) {
  use text <- decode.field("text", decode.string)
  decode.success(TextBlock(text))
}

fn refusal_block_decoder() -> decode.Decoder(ContentBlock) {
  use text <- decode.optional_field("refusal", "", decode.string)
  decode.success(RefusalBlock(text))
}

fn reasoning_block_decoder() -> decode.Decoder(String) {
  use text <- decode.optional_field("text", "", decode.string)
  decode.success(text)
}

fn content_text(blocks: List(ContentBlock)) -> String {
  blocks
  |> list.filter_map(fn(block) {
    case block {
      TextBlock(text) -> Ok(text)
      RefusalBlock(text) -> Ok(text)
      OtherBlock -> Error(Nil)
    }
  })
  |> string.join("")
}

fn block_text(blocks: List(String)) -> String {
  string.join(blocks, "\n\n")
}

fn terminal_event_decoder() -> decode.Decoder(Terminal) {
  use terminal <- decode.subfield(["response"], response_decoder())
  decode.success(terminal)
}

fn response_decoder() -> decode.Decoder(Terminal) {
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  use model <- decode.optional_field(
    "model",
    None,
    decode.optional(decode.string),
  )
  use status <- decode.optional_field("status", "completed", decode.string)
  use incomplete_reason <- decode.optional_field(
    "incomplete_details",
    None,
    decode.optional(decode.at(["reason"], decode.string)),
  )
  use usage <- decode.optional_field(
    "usage",
    None,
    decode.optional(usage_decoder()),
  )
  let stop = case incomplete_reason {
    Some("content_filter") -> stop_reason.Error
    Some("max_output_tokens") -> stop_reason.Length
    _ -> stop_reason.from_responses_status(status)
  }
  decode.success(Terminal(
    response_id: id,
    response_model: model,
    stop_reason: stop,
    input_tokens: option.map(usage, fn(value) { value.input_tokens }),
    output_tokens: option.map(usage, fn(value) { value.output_tokens }),
  ))
}

type Usage {
  Usage(input_tokens: Int, output_tokens: Int)
}

fn usage_decoder() -> decode.Decoder(Usage) {
  use input_tokens <- decode.field("input_tokens", decode.int)
  use output_tokens <- decode.field("output_tokens", decode.int)
  decode.success(Usage(input_tokens:, output_tokens:))
}

fn response_error_decoder() -> decode.Decoder(String) {
  use error <- decode.field("error", nested_error_decoder())
  decode.success(error)
}

fn nested_error_decoder() -> decode.Decoder(String) {
  use message <- decode.field("message", decode.string)
  decode.success(message)
}

fn failed_event_decoder() -> decode.Decoder(String) {
  use response <- decode.optional_field(
    "response",
    "",
    response_error_decoder(),
  )
  case response {
    "" -> decode.success("Responses stream failed")
    message -> decode.success(message)
  }
}

fn error_event_decoder() -> decode.Decoder(String) {
  use direct <- decode.optional_field("message", "", decode.string)
  use nested <- decode.optional_field("error", "", nested_error_decoder())
  case direct {
    "" ->
      case nested {
        "" -> decode.success("Responses provider error")
        message -> decode.success(message)
      }
    message -> decode.success(message)
  }
}
