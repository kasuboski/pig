import gleam/dict
import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/result
import lustre/effect
import omnimessage/server as omniserver
import pig
import pig/run as agent_run
import pig/run_error.{Busy, Rejected, RuntimeStartUnavailable}
import pig_protocol/inference
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

type RelayMessage {
  RunEvent(agent_run.RunEvent)
  RuntimeDown
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
      let owner = process.self()
      #(
        model,
        effect.from(fn(dispatch) {
          case context.get_or_create_agent(model.ctx, agent_id) {
            Ok(pig_agent) ->
              start_stream(
                pig_agent,
                chat_msg.content,
                agent_id,
                chat_msg,
                model.ctx,
                owner,
                dispatch,
              )
            Error(_) -> reject_pending_message(agent_id, chat_msg.id, dispatch)
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

fn start_stream(
  agent: pig.Agent,
  prompt: String,
  agent_id: shared.AgentId,
  user_message: shared.ChatMessage,
  ctx: Context,
  owner: Pid,
  dispatch: fn(Msg) -> Nil,
) -> Nil {
  let sink = process.new_subject()
  case pig.stream_owned(agent, prompt, sink, owner) {
    Ok(run) -> {
      // Pig accepted the run, so application history can now advance with it.
      let sent_msg = shared.ChatMessage(..user_message, status: shared.Sent)
      let placeholder = shared.new_streaming_ai_chat_msg()
      context.add_message(ctx, agent_id, sent_msg)
      dispatch(
        ServerMessage(shared.ServerUpsertChatMessages(agent_id, [sent_msg])),
      )
      // This identity is stable for every delta and is replaced on completion.
      dispatch(
        ServerMessage(shared.ServerUpsertChatMessages(agent_id, [placeholder])),
      )
      let _ =
        process.spawn_unlinked(fn() {
          relay_run_events(run, sink, agent_id, placeholder, ctx, dispatch)
        })
      Nil
    }
    Error(Busy) | Error(Rejected(_)) | Error(RuntimeStartUnavailable) ->
      reject_pending_message(agent_id, user_message.id, dispatch)
  }
}

fn reject_pending_message(
  agent_id: shared.AgentId,
  message_id: String,
  dispatch: fn(Msg) -> Nil,
) -> Nil {
  // The client optimistically rendered this message. Remove it without ever
  // adding it to application history when Pig rejects the run.
  dispatch(ServerMessage(shared.ServerRemoveChatMessage(agent_id, message_id)))
}

fn relay_run_events(
  run: agent_run.Run,
  sink: Subject(agent_run.RunEvent),
  agent_id: shared.AgentId,
  placeholder: shared.ChatMessage,
  ctx: Context,
  dispatch: fn(Msg) -> Nil,
) -> Nil {
  let runtime_monitor = process.monitor(pig.runtime_owner(run))
  let selector =
    process.new_selector()
    |> process.select_map(sink, RunEvent)
    |> process.select_specific_monitor(runtime_monitor, fn(_) { RuntimeDown })
  relay_run_events_from(selector, run, agent_id, placeholder, ctx, dispatch)
}

fn relay_run_events_from(
  selector: Selector(RelayMessage),
  run: agent_run.Run,
  agent_id: shared.AgentId,
  placeholder: shared.ChatMessage,
  ctx: Context,
  dispatch: fn(Msg) -> Nil,
) -> Nil {
  case process.selector_receive_forever(selector) {
    RuntimeDown -> Nil
    RunEvent(event) ->
      case event {
        agent_run.InferenceDelta(_, inference.TextDelta(delta)) -> {
          dispatch(
            ServerMessage(shared.ServerAssistantDelta(
              agent_id,
              placeholder.id,
              delta,
            )),
          )
          relay_run_events_from(
            selector,
            run,
            agent_id,
            placeholder,
            ctx,
            dispatch,
          )
        }
        agent_run.Completed(result) ->
          case result.message {
            message.Assistant(content:, ..) -> {
              let final_message =
                shared.finalize_assistant_message(placeholder, content)
              // Transient deltas never reach Context. Only the canonical
              // completed message is committed and sent as the replacement.
              context.add_message(ctx, agent_id, final_message)
              dispatch(
                ServerMessage(
                  shared.ServerUpsertChatMessages(agent_id, [final_message]),
                ),
              )
            }
            _ -> Nil
          }
        agent_run.Failed(_) | agent_run.Cancelled(_) ->
          // Do not retain or commit partial assistant output after failure.
          dispatch(
            ServerMessage(shared.ServerRemoveChatMessage(
              agent_id,
              placeholder.id,
            )),
          )
        _ ->
          relay_run_events_from(
            selector,
            run,
            agent_id,
            placeholder,
            ctx,
            dispatch,
          )
      }
  }
}
