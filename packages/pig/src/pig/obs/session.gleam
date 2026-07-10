//// JSONL session writer — records SessionEvents to a file for replay.
////
//// OTP actor that receives SessionEvents and appends them as JSONL lines.
//// Two modes:
////   - `record()` — fire-and-forget, never blocks the agent.
////   - `record_sync()` — synchronous call, blocks until written. For testing.

import gleam/dynamic/decode as dynamic_decode
import gleam/erlang/process.{type Name, type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor.{type StartError}
import gleam/otp/supervision
import gleam/string
import pig_protocol/error.{
  type AiError, ApiError, InvalidResponse, RateLimited, Timeout,
}
import pig_protocol/message.{
  type Message, type Thinking, type ToolCall, Assistant, System, Thinking, Tool,
  ToolCall, User,
}
import pig_protocol/stop_reason
import pig/obs/events.{
  type HookPoint, type SessionEndReason, type SessionEvent, AfterInference,
  AfterToolCall, BeforeInference, BeforeToolCall, ErrorEnd, HookActed,
  InferenceCompleted, InferenceFailed, InferenceStarted, Interrupted,
  MaxIterationsExceeded, NormalEnd, OnComplete, OnError, OnSessionShutdown,
  OnSessionStart, SessionEnded, SessionStarted, ToolBlocked, ToolExecuted,
  ToolStarted,
}
import simplifile

// ── FFI Bindings ─────────────────────────────────────────────────────

@external(erlang, "pig_obs_session_ffi", "iso_timestamp")
fn ffi_iso_timestamp() -> String

/// Get current ISO 8601 timestamp.
pub fn iso_timestamp() -> String {
  ffi_iso_timestamp()
}

// ── Actor Types ───────────────────────────────────────────────────────

/// Opaque handle to the session writer actor.
pub opaque type SessionWriter {
  SessionWriter(subject: Subject(WriterMessage))
}

/// Internal actor messages.
type WriterMessage {
  WriteEvent(SessionEvent)
  WriteEventSync(event: SessionEvent, reply_subject: Subject(Nil))
  Stop
}

/// Actor state holds the file path.
type State {
  State(path: String)
}

// ── Public API ────────────────────────────────────────────────────────

/// Start a new session writer actor that appends events to the given file.
pub fn start(path: String) -> Result(SessionWriter, StartError) {
  let builder =
    actor.new(State(path: path))
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(SessionWriter(started.data))
    Error(e) -> Error(e)
  }
}

/// Stop the session writer actor.
pub fn stop(writer: SessionWriter) -> Nil {
  let SessionWriter(subject) = writer
  process.send(subject, Stop)
}

/// Record a session event. Fire-and-forget: does not block.
pub fn record(writer: SessionWriter, event: SessionEvent) -> Nil {
  let SessionWriter(subject) = writer
  process.send(subject, WriteEvent(event))
}

/// Record a session event synchronously. Blocks until the event is
/// written to disk. Use this in tests for deterministic assertions.
pub fn record_sync(writer: SessionWriter, event: SessionEvent) -> Nil {
  let SessionWriter(subject) = writer
  let reply_subject = process.new_subject()
  process.send(subject, WriteEventSync(event:, reply_subject:))
  let assert Ok(_) = process.receive(reply_subject, 5000)
  Nil
}

// ── Replay ────────────────────────────────────────────────────────────

/// Replay error type for session reconstruction.
pub type ReplayError {
  FileError(String)
  ParseError(String)
}

/// Replay a JSONL session file and reconstruct the message history.
///
/// Strategy: find the last InferenceCompleted event. Its input_messages +
/// message give the complete history. For partial sessions (crash mid-loop),
/// also include Tool messages from ToolExecuted events after the last inference.
pub fn replay(path: String) -> Result(List(Message), ReplayError) {
  case simplifile.read(path) {
    Error(e) -> Error(FileError(string.inspect(e)))
    Ok(content) -> {
      let lines =
        content
        |> string.split("\n")
        |> list.filter(fn(l) { l != "" })
      case lines {
        [] -> Ok([])
        _ -> replay_lines(lines)
      }
    }
  }
}

/// Replay from a list of JSONL lines.
fn replay_lines(lines: List(String)) -> Result(List(Message), ReplayError) {
  // Find the last InferenceCompleted event
  let last_inference = find_last_inference_completed(lines)
  case last_inference {
    None -> Ok([])
    Some(input_messages_json) -> {
      // Parse input_messages + message
      case parse_inference_messages(input_messages_json) {
        Ok(messages) -> {
          // Also check for ToolExecuted events after this line
          // (partial session: tools ran but no final inference)
          let remaining = lines_after(lines, input_messages_json)
          let tool_msgs =
            remaining
            |> list.filter_map(fn(line) {
              case decode_event_type_str(line) {
                "tool_executed" -> parse_tool_message(line)
                "tool_blocked" -> parse_blocked_tool_message(line)
                _ -> Error(Nil)
              }
            })
          Ok(list.append(messages, tool_msgs))
        }
        Error(e) -> Error(e)
      }
    }
  }
}

/// Find the last InferenceCompleted line.
fn find_last_inference_completed(lines: List(String)) -> Option(String) {
  lines
  |> list.fold(None, fn(acc, line) {
    case decode_event_type_str(line) {
      "inference_completed" -> Some(line)
      _ -> acc
    }
  })
}

/// Get lines after the given line.
fn lines_after(lines: List(String), target: String) -> List(String) {
  case lines {
    [] -> []
    [l, ..rest] -> {
      case l == target {
        True -> rest
        False -> lines_after(rest, target)
      }
    }
  }
}

/// Decode the event type from a JSON line.
fn decode_event_type_str(line: String) -> String {
  let decoder = dynamic_decode.at(["event"], dynamic_decode.string)
  case json.parse(from: line, using: decoder) {
    Ok(event_type) -> event_type
    Error(_) -> ""
  }
}

/// Parse input_messages and message from an InferenceCompleted JSON line.
fn parse_inference_messages(
  line: String,
) -> Result(List(Message), ReplayError) {
  let input_decoder =
    dynamic_decode.at(["input_messages"], dynamic_decode.list(decode_message()))

  case json.parse(from: line, using: input_decoder) {
    Ok(input_msgs) -> {
      let msg_decoder = dynamic_decode.at(["message"], decode_message())
      case json.parse(from: line, using: msg_decoder) {
        Ok(response_msg) -> Ok(list.append(input_msgs, [response_msg]))
        Error(_) -> Error(ParseError("Failed to parse message: " <> line))
      }
    }
    Error(_) -> Error(ParseError("Failed to parse input_messages: " <> line))
  }
}

/// Parse a Tool message from a ToolExecuted JSON line.
fn parse_tool_message(line: String) -> Result(Message, Nil) {
  let id_decoder = dynamic_decode.at(["tool_call", "id"], dynamic_decode.string)
  let result_decoder = dynamic_decode.at(["result"], dynamic_decode.string)

  case json.parse(from: line, using: id_decoder) {
    Ok(id) -> {
      case json.parse(from: line, using: result_decoder) {
        Ok(result) -> Ok(Tool(tool_call_id: id, content: result))
        Error(_) -> Error(Nil)
      }
    }
    Error(_) -> Error(Nil)
  }
}

/// Parse a Tool message from a ToolBlocked JSON line.
fn parse_blocked_tool_message(line: String) -> Result(Message, Nil) {
  let id_decoder = dynamic_decode.at(["tool_call", "id"], dynamic_decode.string)
  let hook_name_decoder =
    dynamic_decode.at(["hook_name"], dynamic_decode.string)
  let reason_decoder = dynamic_decode.at(["reason"], dynamic_decode.string)

  case json.parse(from: line, using: id_decoder) {
    Ok(id) -> {
      case
        json.parse(from: line, using: hook_name_decoder),
        json.parse(from: line, using: reason_decoder)
      {
        Ok(hook_name), Ok(reason) ->
          Ok(Tool(
            tool_call_id: id,
            content: "Tool blocked by '" <> hook_name <> "': " <> reason,
          ))
        _, _ -> Error(Nil)
      }
    }
    Error(_) -> Error(Nil)
  }
}

/// Decode a Message from JSON.
pub fn decode_message() -> dynamic_decode.Decoder(Message) {
  use role <- dynamic_decode.field("role", dynamic_decode.string)
  case role {
    "user" -> {
      use content <- dynamic_decode.field("content", dynamic_decode.string)
      dynamic_decode.success(User(content:))
    }
    "system" -> {
      use content <- dynamic_decode.field("content", dynamic_decode.string)
      dynamic_decode.success(System(content:))
    }
    "tool" -> {
      use tool_call_id <- dynamic_decode.field(
        "tool_call_id",
        dynamic_decode.string,
      )
      use content <- dynamic_decode.field("content", dynamic_decode.string)
      dynamic_decode.success(Tool(tool_call_id:, content:))
    }
    "assistant" -> {
      use content <- dynamic_decode.field("content", dynamic_decode.string)
      use tool_calls <- dynamic_decode.field(
        "tool_calls",
        dynamic_decode.list(decode_tool_call()),
      )
      use thinking <- dynamic_decode.optional_field(
        "thinking",
        option.None,
        decode_thinking(),
      )
      use stop_reason <- dynamic_decode.optional_field(
        "stop_reason",
        option.None,
        dynamic_decode.optional(stop_reason.decoder()),
      )
      dynamic_decode.success(Assistant(
        content:,
        tool_calls:,
        thinking:,
        stop_reason:,
      ))
    }
    _ ->
      dynamic_decode.failure(
        User(content: ""),
        "unknown message role: " <> role,
      )
  }
}

/// Decode Thinking from JSON.
fn decode_thinking() -> dynamic_decode.Decoder(option.Option(Thinking)) {
  use content <- dynamic_decode.field("content", dynamic_decode.string)
  dynamic_decode.success(option.Some(Thinking(content:)))
}

/// Decode a ToolCall from JSON.
pub fn decode_tool_call() -> dynamic_decode.Decoder(ToolCall) {
  use id <- dynamic_decode.field("id", dynamic_decode.string)
  use name <- dynamic_decode.field("name", dynamic_decode.string)
  use arguments_json <- dynamic_decode.field("arguments", dynamic_decode.string)
  dynamic_decode.success(ToolCall(id:, name:, arguments_json:))
}

/// Start a session consumer actor that accepts SessionEvent directly.
/// Used by the dispatcher to fan out events. Returns the Subject for registration.
/// This is the consumer version of the actor — it receives SessionEvent directly,
/// not WriterMessage wrappers. Fire-and-forget: does not block.
pub fn start_consumer(
  path: String,
) -> Result(Subject(SessionEvent), StartError) {
  let builder =
    actor.new(State(path: path))
    |> actor.on_message(handle_consumer_message)
  case actor.start(builder) {
    Ok(started) -> Ok(started.data)
    Error(e) -> Error(e)
  }
}

/// Create a supervised session consumer actor for use in a supervision tree.
/// The supervised actor's message type is SessionEvent directly (not WriterMessage).
pub fn supervised(
  path: String,
  name: Name(SessionEvent),
) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() {
    let builder =
      actor.new(State(path: path))
      |> actor.on_message(handle_consumer_message)
      |> actor.named(name)
    case actor.start(builder) {
      Ok(started) -> Ok(actor.Started(data: Nil, pid: started.pid))
      Error(e) -> Error(e)
    }
  })
}

/// Format a SessionEvent as a JSON string (pure function, no side effects).
pub fn format_event(event: SessionEvent) -> String {
  let ts = iso_timestamp()

  case event {
    SessionStarted(
      agent_id:,
      agent_name:,
      model:,
      provider_name:,
      system_prompt:,
    ) -> {
      let fields = [
        #("ts", json.string(ts)),
        #("event", json.string("session_started")),
        #("model", json.string(model)),
      ]
      let with_agent_id = case agent_id {
        Some(v) -> list.append(fields, [#("agent_id", json.string(v))])
        None -> fields
      }
      let with_agent_name = case agent_name {
        Some(v) -> list.append(with_agent_id, [#("agent_name", json.string(v))])
        None -> with_agent_id
      }
      let with_provider = case provider_name {
        Some(v) ->
          list.append(with_agent_name, [#("provider_name", json.string(v))])
        None -> with_agent_name
      }
      let with_system = case system_prompt {
        Some(v) ->
          list.append(with_provider, [#("system_prompt", json.string(v))])
        None -> with_provider
      }

      json.object(with_system) |> json.to_string()
    }

    InferenceStarted(model:, message_count:) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("inference_started")),
        #("model", json.string(model)),
        #("message_count", json.int(message_count)),
      ])
      |> json.to_string()
    }

    InferenceCompleted(
      message:,
      response_id:,
      response_model:,
      stop_reason:,
      input_tokens:,
      output_tokens:,
      duration_ms:,
      input_messages:,
    ) -> {
      let fields = [
        #("ts", json.string(ts)),
        #("event", json.string("inference_completed")),
        #("duration_ms", json.int(duration_ms)),
        #("message", message_to_json(message)),
        #("input_messages", json.array(input_messages, message_to_json)),
      ]
      let with_response_id = case response_id {
        Some(v) -> list.append(fields, [#("response_id", json.string(v))])
        None -> fields
      }
      let with_response_model = case response_model {
        Some(v) ->
          list.append(with_response_id, [#("response_model", json.string(v))])
        None -> with_response_id
      }
      let with_stop_reason = case stop_reason {
        Some(v) ->
          list.append(with_response_model, [
            #("stop_reason", stop_reason.to_json(v)),
          ])
        None -> with_response_model
      }
      let with_input_tokens = case input_tokens {
        Some(v) ->
          list.append(with_stop_reason, [#("input_tokens", json.int(v))])
        None -> with_stop_reason
      }
      let with_output_tokens = case output_tokens {
        Some(v) ->
          list.append(with_input_tokens, [#("output_tokens", json.int(v))])
        None -> with_input_tokens
      }

      json.object(with_output_tokens) |> json.to_string()
    }

    ToolStarted(tool_call:) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("tool_started")),
        #("tool_call", tool_call_to_json(tool_call)),
      ])
      |> json.to_string()
    }

    ToolExecuted(tool_call:, result:, duration_ms:) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("tool_executed")),
        #("duration_ms", json.int(duration_ms)),
        #("tool_call", tool_call_to_json(tool_call)),
        #("result", json.string(result)),
      ])
      |> json.to_string()
    }

    ToolBlocked(tool_call:, hook_name:, reason:) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("tool_blocked")),
        #("tool_call", tool_call_to_json(tool_call)),
        #("hook_name", json.string(hook_name)),
        #("reason", json.string(reason)),
      ])
      |> json.to_string()
    }

    HookActed(hook_name:, hook_point:, action:) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("hook_acted")),
        #("hook_name", json.string(hook_name)),
        #("hook_point", json.string(hook_to_string(hook_point))),
        #(
          "action",
          json.object([
            #("action_type", json.string(action.action_type)),
            #("description", json.string(action.description)),
          ]),
        ),
      ])
      |> json.to_string()
    }

    InferenceFailed(error:, duration_ms:, input_messages:) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("inference_failed")),
        #("duration_ms", json.int(duration_ms)),
        #("error", error_to_json(error)),
        #("input_messages", json.array(input_messages, message_to_json)),
      ])
      |> json.to_string()
    }

    SessionEnded(reason:) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("session_ended")),
        #("reason", reason_to_json(reason)),
      ])
      |> json.to_string()
    }
  }
}

// ── Actor Implementation ───────────────────────────────────────────────

fn handle_message(
  state: State,
  message: WriterMessage,
) -> actor.Next(State, WriterMessage) {
  case message {
    WriteEvent(event) -> {
      let json_str = format_event(event)
      let _ = simplifile.append(state.path, json_str <> "\n")
      actor.continue(state)
    }
    WriteEventSync(event:, reply_subject:) -> {
      let json_str = format_event(event)
      let _ = simplifile.append(state.path, json_str <> "\n")
      process.send(reply_subject, Nil)
      actor.continue(state)
    }
    Stop -> {
      actor.stop()
    }
  }
}

/// Handle consumer messages (SessionEvent directly, not wrapped in WriterMessage).
/// Used by the supervised consumer actor that receives events from the dispatcher.
fn handle_consumer_message(
  state: State,
  event: SessionEvent,
) -> actor.Next(State, SessionEvent) {
  let json_str = format_event(event)
  case simplifile.append(state.path, json_str <> "\n") {
    Ok(_) -> actor.continue(state)
    Error(_) -> {
      // Stop on write failure so the supervisor can restart the consumer.
      // Silently continuing would lose events without any signal.
      actor.stop()
    }
  }
}

// ── JSON Serialization Helpers ────────────────────────────────────────

fn message_to_json(msg: Message) -> json.Json {
  case msg {
    User(content:) -> {
      json.object([
        #("role", json.string("user")),
        #("content", json.string(content)),
      ])
    }
    System(content:) -> {
      json.object([
        #("role", json.string("system")),
        #("content", json.string(content)),
      ])
    }
    Assistant(content:, tool_calls:, thinking:, stop_reason:) -> {
      let base_fields = [
        #("role", json.string("assistant")),
        #("content", json.string(content)),
        #("tool_calls", json.array(tool_calls, tool_call_to_json)),
      ]
      let fields_with_thinking = case thinking {
        Some(t) -> {
          case t {
            Thinking(content:) -> {
              list.append(base_fields, [
                #("thinking", json.object([#("content", json.string(content))])),
              ])
            }
          }
        }
        None -> base_fields
      }
      let fields_with_stop_reason = case stop_reason {
        Some(sr) ->
          list.append(fields_with_thinking, [
            #("stop_reason", stop_reason.to_json(sr)),
          ])
        None -> fields_with_thinking
      }

      json.object(fields_with_stop_reason)
    }
    Tool(tool_call_id:, content:) -> {
      json.object([
        #("role", json.string("tool")),
        #("tool_call_id", json.string(tool_call_id)),
        #("content", json.string(content)),
      ])
    }
  }
}

fn tool_call_to_json(tc: ToolCall) -> json.Json {
  json.object([
    #("id", json.string(tc.id)),
    #("name", json.string(tc.name)),
    #("arguments", json.string(tc.arguments_json)),
  ])
}

fn error_to_json(error: AiError) -> json.Json {
  case error {
    ApiError(message:) -> {
      json.object([
        #("type", json.string("api_error")),
        #("message", json.string(message)),
      ])
    }
    RateLimited -> {
      json.object([#("type", json.string("rate_limited"))])
    }
    Timeout -> {
      json.object([#("type", json.string("timeout"))])
    }
    InvalidResponse(detail:) -> {
      json.object([
        #("type", json.string("invalid_response")),
        #("detail", json.string(detail)),
      ])
    }
  }
}

fn reason_to_json(reason: SessionEndReason) -> json.Json {
  case reason {
    NormalEnd -> {
      json.object([#("type", json.string("normal_end"))])
    }
    ErrorEnd(e) -> {
      json.object([
        #("type", json.string("error")),
        #("error", error_to_json(e)),
      ])
    }
    MaxIterationsExceeded(n) -> {
      json.object([
        #("type", json.string("max_iterations_exceeded")),
        #("max_iterations", json.int(n)),
      ])
    }
    Interrupted -> {
      json.object([#("type", json.string("interrupted"))])
    }
  }
}

fn hook_to_string(hook: HookPoint) -> String {
  case hook {
    BeforeToolCall -> "before_tool_call"
    AfterToolCall -> "after_tool_call"
    BeforeInference -> "before_inference"
    AfterInference -> "after_inference"
    OnError -> "on_error"
    OnComplete -> "on_complete"
    OnSessionStart -> "on_session_start"
    OnSessionShutdown -> "on_session_shutdown"
  }
}
