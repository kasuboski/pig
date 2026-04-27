//// Centralized test harness for pig/agent tests.
////
//// Single place for mock providers, test tools, and state construction.
//// If the API boundary changes, update HERE — all tests follow.
////
//// Per TESTING_STRATEGY §Axiom 3: "If our API boundary changes,
//// we update *one* `check` function, instantly fixing hundreds of tests."

import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import jscheam/schema
import pig/agent/core
import pig/agent/state
import pig/ai/error
import pig/ai/message
import pig/ai/provider
import pig/ai/tool_definition
import pig/obs/events
import pig/obs/listener
import pig/tool

// ── Public: check helpers (behavioral assertions) ────────────────

/// Run a scenario: provide initial user message, a sequence of provider
/// responses, and a set of tools. Returns the final message or error.
///
/// This is the primary entry point for agent scenario tests.
pub fn check_scenario(
  user_message: String,
  provider_responses: List(message.Message),
  tools: List(tool.Tool),
) -> Result(message.Message, error.AiError) {
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let provider = sequenced_provider_for_actor(provider_responses)
  let st =
    state.config(provider)
    |> state.with_tools(registry)
    |> state.new()
    |> state.add_message(message.User(user_message))
  core.run_to_completion(st)
}

/// Check that a simple text exchange completes successfully.
pub fn check_simple_response(
  user_message: String,
  response: message.Message,
) -> Bool {
  case check_scenario(user_message, [response], []) {
    Ok(msg) -> msg == response
    Error(_) -> False
  }
}

/// Build a state for step-level tests.
pub fn state_for_step(
  provider_responses: List(message.Message),
  tools: List(tool.Tool),
) -> state.AgentState {
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let provider = sequenced_provider_for_actor(provider_responses)
  state.config(provider)
    |> state.with_tools(registry)
    |> state.new()
}

/// Build a state with explicit max iterations (for circuit breaker tests).
pub fn state_with_max_iterations(
  provider_responses: List(message.Message),
  tools: List(tool.Tool),
  max: Int,
) -> state.AgentState {
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let provider = sequenced_provider_for_actor(provider_responses)
  state.config(provider)
    |> state.with_tools(registry)
    |> state.with_max_iterations(max)
    |> state.new()
}

/// Build a state with a system prompt.
pub fn state_with_system_prompt(
  provider_responses: List(message.Message),
  tools: List(tool.Tool),
  prompt: String,
) -> state.AgentState {
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let provider = sequenced_provider_for_actor(provider_responses)
  state.config(provider)
    |> state.with_tools(registry)
    |> state.with_system_prompt(prompt)
    |> state.new()
}

// ── Public: test tools ───────────────────────────────────────────

/// A tool that echoes back the "msg" field from arguments.
pub fn echo_tool() -> tool.Tool {
  tool.Tool(
    definition:
      tool_definition.ToolDefinition(
        name: "echo",
        description: "Echoes back",
        parameters: schema.object([]),
      ),
    handler: fn(args: dynamic.Dynamic) -> Result(json.Json, tool.ToolError) {
      let assert Ok(msg) =
        decode.run(args, decode.field("msg", decode.string, decode.success))
      Ok(json.object([#("echo", json.string(msg))]))
    },
  )
}

/// A tool that always fails.
pub fn failing_tool() -> tool.Tool {
  tool.Tool(
    definition:
      tool_definition.ToolDefinition(
        name: "boom",
        description: "Always fails",
        parameters: schema.object([]),
      ),
    handler: fn(_) {
      Error(tool.ToolError(message: "tool exploded"))
    },
  )
}

// ── Public: mock providers ───────────────────────────────────────

/// Provider that returns a fixed response every call.
pub fn fixed_provider(
  response: message.Message,
) -> fn(
  List(message.Message),
  List(tool_definition.ToolDefinition),
) ->
  Result(provider.InferenceResult, error.AiError) {
  fn(_msgs, _tools) { Ok(provider.from_message(response)) }
}

/// Provider that always fails.
pub fn failing_provider(
  _msgs: List(message.Message),
  _tools: List(tool_definition.ToolDefinition),
) -> Result(provider.InferenceResult, error.AiError) {
  Error(error.ApiError("provider failed"))
}

// ── Public: sequenced provider for actor tests ──────────────────

/// Provider that returns responses in sequence.
/// Tracks position by counting assistant messages in the history it receives.
/// Public so actor tests can construct a Provider value for AgentConfig.
pub fn sequenced_provider_for_actor(
  responses: List(message.Message),
) -> fn(
  List(message.Message),
  List(tool_definition.ToolDefinition),
) ->
  Result(provider.InferenceResult, error.AiError) {
  fn(msgs, _tools) {
    let idx = count_assistant_messages(msgs)
    case nth(responses, idx) {
      Ok(msg) -> Ok(provider.from_message(msg))
      Error(_) ->
        Error(error.ApiError(
          "mock: no response at index " <> int.to_string(idx),
        ))
    }
  }
}

fn nth(lst: List(a), idx: Int) -> Result(a, Nil) {
  lst |> list.drop(idx) |> list.first
}

fn count_assistant_messages(msgs: List(message.Message)) -> Int {
  msgs
  |> list.filter(fn(m) {
    case m {
      message.Assistant(..) -> True
      _ -> False
    }
  })
  |> list.length()
}

// ── Telemetry Capture ────────────────────────────────────────────

/// Run a scenario with telemetry capture. Returns (result, events).
pub fn capture_scenario(
  user_message: String,
  responses: List(message.Message),
  tools: List(tool.Tool),
  model: String,
) -> #(
  Result(message.Message, error.AiError),
  List(events.Event),
) {
  let handle = listener.attach()
  let registry = list.fold(tools, tool.new_registry(), tool.register)
  let provider = sequenced_provider_for_actor(responses)
  let st =
    state.config(provider)
    |> state.with_tools(registry)
    |> state.with_model(model)
    |> state.new()
    |> state.add_message(message.User(user_message))
  let result = core.run_to_completion(st)
  let evts = listener.get_events(handle)
  listener.detach(handle)
  #(result, evts)
}

/// Extract event type names from a list of events.
pub fn event_type_names(evts: List(events.Event)) -> List(String) {
  evts
  |> list.map(fn(e) {
    events.name_to_string(events.event_name(e))
  })
}
