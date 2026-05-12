import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/otp/actor
import gleam/result

import pig.{type Agent}
import server/agents
import shared.{type AgentId, type ChatMessage}

pub type Context =
  process.Subject(Message)

pub type Message {
  GetMessages(AgentId, process.Subject(List(ChatMessage)))
  AddMessage(AgentId, ChatMessage)
  GetOrCreateAgent(AgentId, process.Subject(Agent))
  Shutdown
}

type ContextState {
  ContextState(
    messages: Dict(AgentId, List(ChatMessage)),
    agents: Dict(AgentId, Agent),
  )
}

fn handle_message(state: ContextState, message: Message) {
  case message {
    Shutdown -> actor.stop()

    GetMessages(agent_id, reply_to) -> {
      let msgs = dict.get(state.messages, agent_id) |> result.unwrap([])
      process.send(reply_to, msgs)
      actor.continue(state)
    }

    AddMessage(agent_id, msg) -> {
      let existing = dict.get(state.messages, agent_id) |> result.unwrap([])
      let new_msgs = [msg, ..existing]
      let new_state =
        ContextState(
          ..state,
          messages: dict.insert(state.messages, agent_id, new_msgs),
        )
      actor.continue(new_state)
    }

    GetOrCreateAgent(agent_id, reply_to) -> {
      case dict.get(state.agents, agent_id) {
        Ok(agent) -> {
          process.send(reply_to, agent)
          actor.continue(state)
        }
        Error(_) -> {
          // Create new pig agent
          case agents.get_persona(agent_id) {
            Ok(persona) -> {
              let config = agents.create_agent_config(persona)
              case pig.start(config) {
                Ok(agent) -> {
                  let new_state =
                    ContextState(
                      ..state,
                      agents: dict.insert(state.agents, agent_id, agent),
                    )
                  process.send(reply_to, agent)
                  actor.continue(new_state)
                }
                Error(_) -> {
                  // Can't send error via Subject, just continue
                  actor.continue(state)
                }
              }
            }
            Error(_) -> actor.continue(state)
          }
        }
      }
    }
  }
}

pub fn new() {
  ContextState(messages: dict.new(), agents: dict.new())
  |> actor.new()
  |> actor.on_message(handle_message)
  |> actor.start()
  |> result.replace_error(Nil)
}

const timeout = 5000

pub fn get_messages(ctx: Context, agent_id: AgentId) -> List(ChatMessage) {
  actor.call(ctx, waiting: timeout, sending: fn(reply_to) {
    GetMessages(agent_id, reply_to)
  })
}

pub fn add_message(ctx: Context, agent_id: AgentId, msg: ChatMessage) {
  process.send(ctx, AddMessage(agent_id, msg))
}

pub fn get_or_create_agent(
  ctx: Context,
  agent_id: AgentId,
) -> Result(Agent, Nil) {
  // actor.call panics on timeout rather than returning Error,
  // so this always returns Ok. To propagate timeouts, use
  // pig.try_run_with_timeout instead of actor.call.
  actor.call(ctx, waiting: timeout, sending: fn(reply_to) {
    GetOrCreateAgent(agent_id, reply_to)
  })
  |> Ok
}
