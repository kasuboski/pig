import gleam/dict
import gleam/result
import lustre/effect
import omnimessage/server as omniserver
import pig
import pig_protocol/message
import server/context.{type Context}
import shared.{type ClientMessage, type ServerMessage}

pub fn app() {
  let encoder_decoder =
    omniserver.EncoderDecoder(
      fn(msg) {
        case msg {
          ServerMessage(message) -> Ok(shared.encode_server_message(message))
          _ -> Error(Nil)
        }
      },
      fn(encoded_msg) {
        shared.decode_client_message(encoded_msg)
        |> result.map(ClientMessage)
      },
    )

  omniserver.application(init, update, encoder_decoder)
}

pub type Model {
  Model(
    messages: dict.Dict(String, shared.ChatMessage),
    ctx: Context,
    current_agent_id: shared.AgentId,
  )
}

fn init(ctx: Context) -> #(Model, effect.Effect(Msg)) {
  #(Model(messages: dict.new(), ctx:, current_agent_id: ""), effect.none())
}

pub type Msg {
  ClientMessage(ClientMessage)
  ServerMessage(ServerMessage)
}

pub fn update(model: Model, msg: Msg) {
  case msg {
    ClientMessage(shared.SelectAgent(agent_id)) -> {
      #(
        Model(..model, current_agent_id: agent_id),
        effect.from(fn(dispatch) {
          // Get or create pig agent for this persona
          let _ = context.get_or_create_agent(model.ctx, agent_id)

          // Get existing messages
          let msgs = context.get_messages(model.ctx, agent_id)

          msgs
          |> shared.AgentSelected(agent_id, _)
          |> ServerMessage
          |> dispatch
        }),
      )
    }

    ClientMessage(shared.UserSendChatMessage(agent_id, chat_msg)) -> {
      #(
        model,
        effect.from(fn(dispatch) {
          // Save user message as Sent
          let sent_msg = shared.ChatMessage(..chat_msg, status: shared.Sent)
          context.add_message(model.ctx, agent_id, sent_msg)

          // Reply with sent message
          [sent_msg]
          |> shared.ServerUpsertChatMessages(agent_id, _)
          |> ServerMessage
          |> dispatch

          // Get the pig agent and run async
          let agent = context.get_or_create_agent(model.ctx, agent_id)
          case agent {
            Ok(pig_agent) -> {
              case pig.run_with_timeout(pig_agent, chat_msg.content, 120_000) {
                Ok(message.Assistant(content:, ..)) -> {
                  let ai_msg = shared.new_ai_chat_msg(content:)
                  context.add_message(model.ctx, agent_id, ai_msg)
                  [ai_msg]
                  |> shared.ServerUpsertChatMessages(agent_id, _)
                  |> ServerMessage
                  |> dispatch
                }
                _ -> {
                  let error_msg =
                    shared.new_ai_chat_msg(
                      content: "I seem to have lost my train of thought. Please try again.",
                    )
                  context.add_message(model.ctx, agent_id, error_msg)
                  [error_msg]
                  |> shared.ServerUpsertChatMessages(agent_id, _)
                  |> ServerMessage
                  |> dispatch
                }
              }
            }
            Error(_) -> Nil
          }
        }),
      )
    }

    ClientMessage(shared.FetchChatMessages(agent_id)) -> {
      #(
        model,
        effect.from(fn(dispatch) {
          let msgs = context.get_messages(model.ctx, agent_id)
          msgs
          |> shared.ServerUpsertChatMessages(agent_id, _)
          |> ServerMessage
          |> dispatch
        }),
      )
    }

    ServerMessage(_) -> #(model, effect.none())
  }
}
