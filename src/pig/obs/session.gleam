//// JSONL session writer — records SessionEvents to a file for replay.
////
//// OTP actor that receives SessionEvents and appends them as JSONL lines.
//// Two modes:
////   - `record()` — fire-and-forget, never blocks the agent.
////   - `record_sync()` — synchronous call, blocks until written. For testing.

import gleam/erlang/process.{type Subject, type Name}
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor.{type StartError}
import gleam/otp/supervision
import pig/ai/error.{type AiError, ApiError, RateLimited, Timeout, InvalidResponse}
import pig/ai/message.{type Message, type ToolCall, User, System, Assistant, Tool, Thinking}
import pig/obs/events.{type SessionEndReason, type SessionEvent, type ExtensionHook, NormalEnd, ErrorEnd, MaxIterationsExceeded, Interrupted, SessionStarted, InferenceStarted, InferenceCompleted, ToolStarted, ToolExecuted, ToolBlocked, ExtensionActed, InferenceFailed, SessionEnded, BeforeToolCall, AfterToolCall, BeforeInference, AfterInference, OnError}
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

/// Start a session consumer actor that accepts SessionEvent directly.
/// Used by the dispatcher to fan out events. Returns the Subject for registration.
/// This is the consumer version of the actor — it receives SessionEvent directly,
/// not WriterMessage wrappers. Fire-and-forget: does not block.
pub fn start_consumer(path: String) -> Result(Subject(SessionEvent), StartError) {
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
      let fields =
        [
          #("ts", json.string(ts)),
          #("event", json.string("session_started")),
          #("model", json.string(model)),
        ]
      let with_agent_id =
        case agent_id {
          Some(v) -> list.append(fields, [#("agent_id", json.string(v))])
          None -> fields
        }
      let with_agent_name =
        case agent_name {
          Some(v) -> list.append(with_agent_id, [#("agent_name", json.string(v))])
          None -> with_agent_id
        }
      let with_provider =
        case provider_name {
          Some(v) -> list.append(with_agent_name, [#("provider_name", json.string(v))])
          None -> with_agent_name
        }
      let with_system =
        case system_prompt {
          Some(v) -> list.append(with_provider, [#("system_prompt", json.string(v))])
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
      finish_reason:,
      input_tokens:,
      output_tokens:,
      duration_ms:,
      input_messages:,
    ) -> {
      let fields =
        [
          #("ts", json.string(ts)),
          #("event", json.string("inference_completed")),
          #("duration_ms", json.int(duration_ms)),
          #("message", message_to_json(message)),
          #("input_messages", json.array(input_messages, message_to_json)),
        ]
      let with_response_id =
        case response_id {
          Some(v) -> list.append(fields, [#("response_id", json.string(v))])
          None -> fields
        }
      let with_response_model =
        case response_model {
          Some(v) -> list.append(with_response_id, [#("response_model", json.string(v))])
          None -> with_response_id
        }
      let with_finish_reason =
        case finish_reason {
          Some(v) -> list.append(with_response_model, [#("finish_reason", json.string(v))])
          None -> with_response_model
        }
      let with_input_tokens =
        case input_tokens {
          Some(v) -> list.append(with_finish_reason, [#("input_tokens", json.int(v))])
          None -> with_finish_reason
        }
      let with_output_tokens =
        case output_tokens {
          Some(v) -> list.append(with_input_tokens, [#("output_tokens", json.int(v))])
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

    ToolBlocked(tool_call:, extension_name:, reason:) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("tool_blocked")),
        #("tool_call", tool_call_to_json(tool_call)),
        #("extension_name", json.string(extension_name)),
        #("reason", json.string(reason)),
      ])
      |> json.to_string()
    }

    ExtensionActed(extension_name:, hook:, action:) -> {
      json.object([
        #("ts", json.string(ts)),
        #("event", json.string("extension_acted")),
        #("extension_name", json.string(extension_name)),
        #("hook", json.string(hook_to_string(hook))),
        #("action", json.object([
          #("action_type", json.string(action.action_type)),
          #("description", json.string(action.description)),
        ])),
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
fn handle_consumer_message(state: State, event: SessionEvent) -> actor.Next(State, SessionEvent) {
  let json_str = format_event(event)
  let _ = simplifile.append(state.path, json_str <> "\n")
  actor.continue(state)
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
    Assistant(content:, tool_calls:, thinking:) -> {
      let base_fields =
        [
          #("role", json.string("assistant")),
          #("content", json.string(content)),
          #("tool_calls", json.array(tool_calls, tool_call_to_json)),
        ]
      let fields =
        case thinking {
          Some(t) -> {
            case t {
              Thinking(content:) -> {
                list.append(base_fields, [
                  #("thinking", json.object([#("content", json.string(content))]))
                ])
              }
            }
          }
          None -> base_fields
        }

      json.object(fields)
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
      json.object([#("type", json.string("error")), #("error", error_to_json(e))])
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

fn hook_to_string(hook: ExtensionHook) -> String {
  case hook {
    BeforeToolCall -> "before_tool_call"
    AfterToolCall -> "after_tool_call"
    BeforeInference -> "before_inference"
    AfterInference -> "after_inference"
    OnError -> "on_error"
  }
}
