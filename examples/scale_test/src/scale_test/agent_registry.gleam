//// Agent registry — lazy pig agent lifecycle management.
//// Creates pig agents on first think request, destroys on death.
//// NOTE: Not currently used by the scheduler (which uses one-shot agents).
//// Retained for Phase 3 optimization.

import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import pig
import pig/ai/openai
import scale_test/grid.{type OrganismType, Herbivore, Plant, Predator}

/// Opaque handle to a running pig agent.
pub type AgentHandle {
  AgentHandle(agent: pig.Agent, otype: OrganismType)
}

/// Messages the agent registry can receive.
pub type RegistryMsg {
  /// Get or create an agent for the given organism. Replies with the agent handle.
  GetOrCreate(
    id: String,
    otype: OrganismType,
    reply_subject: Subject(Result(AgentHandle, Nil)),
  )
  /// Remove an agent (organism died).
  Remove(id: String)
}

pub type RegistryModel {
  RegistryModel(
    agents: dict.Dict(String, AgentHandle),
    base_url: String,
    api_key: String,
    model: String,
  )
}

fn system_prompt(otype: OrganismType) -> String {
  case otype {
    Herbivore ->
      "You are a herbivore rabbit in an ecosystem simulation. Survive by eating plants, avoid predators, reproduce when healthy. Respond with exactly one word: north, south, east, west, eat, reproduce, rest, or wander."
    Predator ->
      "You are a predator wolf in an ecosystem simulation. Hunt herbivores for food, reproduce when healthy. Respond with exactly one word: north, south, east, west, eat, reproduce, rest, or wander."
    Plant ->
      "You are a plant. You don't think."
  }
}

pub fn start(
  base_url: String,
  api_key: String,
  model: String,
) -> actor.StartResult(Subject(RegistryMsg)) {
  let model_state = RegistryModel(
    agents: dict.new(),
    base_url:,
    api_key:,
    model:,
  )
  actor.new(model_state)
    |> actor.on_message(handle_message)
    |> actor.start
}

fn handle_message(model: RegistryModel, msg: RegistryMsg) ->
    actor.Next(RegistryModel, RegistryMsg) {
  case msg {
    GetOrCreate(id, otype, reply_to) -> {
      case dict.get(model.agents, id) {
        Ok(handle) -> {
          process.send(reply_to, Ok(handle))
          actor.continue(model)
        }
        Error(_) -> {
          let provider =
            openai.provider_with_base_url(
              model.api_key,
              model.model,
              model.base_url,
            )
          let cfg =
            pig.new(provider.call)
            |> pig.with_model(model.model)
            |> pig.with_system_prompt(system_prompt(otype))
            |> pig.with_agent_name(id)
          case pig.start(cfg) {
            Ok(agent) -> {
              let handle = AgentHandle(agent:, otype:)
              let agents = dict.insert(model.agents, id, handle)
              process.send(reply_to, Ok(handle))
              actor.continue(RegistryModel(..model, agents:))
            }
            Error(_) -> {
              process.send(reply_to, Error(Nil))
              actor.continue(model)
            }
          }
        }
      }
    }
    Remove(id) -> {
      case dict.get(model.agents, id) {
        Ok(handle) -> {
          pig.stop(handle.agent)
          actor.continue(RegistryModel(
            ..model,
            agents: dict.delete(model.agents, id),
          ))
        }
        Error(_) -> actor.continue(model)
      }
    }
  }
}
