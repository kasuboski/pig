import birl
import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

import lustre/effect
import lustre_pipes/attribute
import lustre_pipes/element
import lustre_pipes/element/html
import lustre_pipes/event
import omnimessage/lustre as omniclient
import omnimessage/lustre/transports
import plinth/browser/document
import plinth/browser/element as plinth_element

import client/agents
import shared.{
  type AgentId, type AgentInfo, type ChatMessage, type ClientMessage,
  type ServerMessage, AgentInfo,
}

// MAIN ------------------------------------------------------------------------

pub fn chat() {
  let encoder_decoder =
    omniclient.EncoderDecoder(
      fn(msg) {
        case msg {
          // Messages must be encodable
          ClientMessage(message) -> Ok(shared.encode_client_message(message))
          // Return Error(Nil) for messages you don't want to send out
          _ -> Error(Nil)
        }
      },
      fn(encoded_msg) {
        // Unsupported messages will cause TransportError(DecodeError(error))
        shared.decode_server_message(encoded_msg)
        |> result.map(ServerMessage)
      },
    )

  omniclient.component(
    init,
    update,
    view,
    [],
    encoder_decoder,
    transports.websocket("http://localhost:8000/omni-app-ws"),
    TransportState,
  )
}

// MODEL -----------------------------------------------------------------------

pub type Model {
  Model(
    current_agent: Option(AgentId),
    messages: dict.Dict(String, ChatMessage),
    draft_content: String,
    agents: List(AgentInfo),
    connected: Bool,
  )
}

const hardcoded_agents = [
  AgentInfo(
    "elf",
    "Elara the Elf",
    "A wise high elf who speaks in archaic prose about magic and nature",
  ),
  AgentInfo(
    "marketer",
    "Marketing Maven",
    "A seasoned marketing expert who analyzes everything through a business lens",
  ),
  AgentInfo(
    "pm",
    "Project Maven",
    "An organized project manager who structures ideas into action plans",
  ),
]

fn init(_initial_model: Option(Model)) -> #(Model, effect.Effect(Msg)) {
  #(
    Model(
      current_agent: None,
      messages: dict.new(),
      draft_content: "",
      agents: hardcoded_agents,
      connected: False,
    ),
    effect.none(),
  )
}

// UPDATE ----------------------------------------------------------------------

pub type Msg {
  UserSendDraft
  UserScrollToLatest
  UserUpdateDraftContent(String)
  UserSelectAgent(AgentId)
  UserGoBack
  ClientMessage(ClientMessage)
  ServerMessage(ServerMessage)
  TransportState(transports.TransportState(json.DecodeError))
}

fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    // Good old UI
    UserUpdateDraftContent(content) -> #(
      Model(..model, draft_content: content),
      effect.none(),
    )
    UserSelectAgent(agent_id) -> {
      #(
        Model(..model, current_agent: Some(agent_id)),
        effect.from(fn(dispatch) {
          dispatch(ClientMessage(shared.SelectAgent(agent_id)))
        }),
      )
    }
    UserGoBack -> #(Model(..model, current_agent: None), effect.none())
    UserSendDraft -> {
      case model.current_agent {
        None -> #(model, effect.none())
        Some(agent_id) -> {
          let chat_msg =
            shared.new_chat_msg(model.draft_content, shared.Sending)
          #(
            Model(
              ..model,
              draft_content: "",
              messages: dict.insert(model.messages, chat_msg.id, chat_msg),
            ),
            effect.from(fn(dispatch) {
              dispatch(
                ClientMessage(shared.UserSendChatMessage(agent_id, chat_msg)),
              )
              dispatch(UserScrollToLatest)
            }),
          )
        }
      }
    }
    UserScrollToLatest -> #(model, scroll_to_latest_message())
    // Shared messages
    ClientMessage(shared.UserSendChatMessage(_agent_id, chat_msg)) -> {
      let messages = dict.insert(model.messages, chat_msg.id, chat_msg)
      #(Model(..model, messages:), scroll_to_latest_message())
    }
    // The rest of the ClientMessages are exclusively handled by the server
    ClientMessage(_) -> {
      #(model, effect.none())
    }
    // Merge strategy
    ServerMessage(shared.ServerUpsertChatMessages(_agent_id, server_messages)) -> {
      let messages =
        model.messages
        // Omnimessage shines when you're OK with server being source of truth
        |> dict.merge(dict.from_list(
          server_messages |> list.map(fn(m) { #(m.id, m) }),
        ))

      #(Model(..model, messages:), effect.none())
    }
    ServerMessage(shared.ServerAssistantDelta(_agent_id, message_id, delta)) -> {
      let messages = case dict.get(model.messages, message_id) {
        Ok(message) if message.is_ai ->
          dict.insert(
            model.messages,
            message_id,
            shared.append_assistant_delta(message, delta),
          )
        Ok(_) | Error(_) -> model.messages
      }

      #(Model(..model, messages:), effect.none())
    }
    ServerMessage(shared.ServerRemoveChatMessage(_agent_id, message_id)) -> {
      #(
        Model(..model, messages: dict.delete(model.messages, message_id)),
        effect.none(),
      )
    }
    ServerMessage(shared.AgentSelected(agent_id, messages)) -> {
      let messages_dict =
        messages
        |> list.map(fn(m) { #(m.id, m) })
        |> dict.from_list

      #(
        Model(..model, current_agent: Some(agent_id), messages: messages_dict),
        scroll_to_latest_message(),
      )
    }
    ServerMessage(shared.AgentList(agents)) -> {
      // Update agents from server (optional - we hardcode them)
      #(Model(..model, agents:), effect.none())
    }
    // State handlers - use for initialization, debug, online/offline indicator
    TransportState(transports.TransportUp) -> {
      #(Model(..model, connected: True), effect.none())
    }
    TransportState(transports.TransportDown(_, _)) -> {
      // Use this for debugging, online/offline indicator
      #(Model(..model, connected: False), effect.none())
    }
    TransportState(transports.TransportError(_)) -> {
      // Use this for debugging, online/offline indicator
      #(model, effect.none())
    }
  }
}

const msgs_container_id = "chat-msgs"

fn scroll_to_latest_message() {
  effect.from(fn(_dispatch) {
    let _ =
      document.get_element_by_id(msgs_container_id)
      |> result.try(fn(container) {
        plinth_element.scroll_height(container)
        |> plinth_element.set_scroll_top(container, _)
        Ok(Nil)
      })

    Nil
  })
}

// VIEW ------------------------------------------------------------------------

fn chat_message_element(chat_msg: ChatMessage) {
  let alignment = case chat_msg.is_ai {
    True -> "items-start"
    False -> "items-end"
  }

  let bubble_class = case chat_msg.is_ai {
    True -> "bg-gray-200 text-gray-800 rounded-2xl rounded-tl-sm"
    False -> "bg-blue-600 text-white rounded-2xl rounded-tr-sm"
  }

  let status_indicator = case chat_msg.status {
    shared.Streaming -> " ..."
    shared.Sending -> " 🕐"
    shared.ClientError -> " ❌"
    shared.ServerError -> " ⚠️"
    _ -> ""
  }

  html.div()
  |> attribute.class("flex w-full " <> alignment)
  |> element.children([
    html.div()
    |> attribute.class("max-w-[80%] p-3 " <> bubble_class)
    |> element.children([
      html.p()
      |> attribute.class("break-words")
      |> element.text_content(chat_msg.content <> status_indicator),
    ]),
  ])
}

fn sort_chat_messages(chat_msgs: List(ChatMessage)) {
  use msg_a, msg_b <- list.sort(chat_msgs)
  birl.compare(msg_a.sent_at, msg_b.sent_at)
}

fn view(model: Model) -> element.Element(Msg) {
  case model.current_agent {
    None -> {
      html.div()
      |> attribute.class("h-full w-full bg-gray-50")
      |> element.children([
        agents.agent_selection_view(model.agents)
        |> element.map(fn(msg) {
          case msg {
            agents.UserSelectAgent(agent_id) -> UserSelectAgent(agent_id)
          }
        }),
      ])
    }
    Some(agent_id) -> {
      let agent_info =
        model.agents
        |> list.find(fn(a) { a.id == agent_id })
        |> result.unwrap(AgentInfo("", "Unknown", ""))

      let sorted_chat_msgs =
        model.messages
        |> dict.values
        |> sort_chat_messages

      html.div()
      |> attribute.class("h-full w-full flex flex-col bg-gray-50")
      |> element.children([
        // Header with back button
        html.div()
          |> attribute.class(
            "flex items-center gap-3 p-4 bg-white border-b border-gray-200 shadow-sm",
          )
          |> element.children([
            html.button()
              |> attribute.class(
                "p-2 hover:bg-gray-100 rounded-lg transition-colors text-gray-600",
              )
              |> event.on_click(UserGoBack)
              |> element.children([
                html.span()
                |> attribute.class("text-xl")
                |> element.text_content("←"),
              ]),
            html.div()
              |> attribute.class("flex items-center gap-2")
              |> element.children([
                html.div()
                  |> attribute.class("w-2 h-2 rounded-full")
                  |> attribute.class(case model.connected {
                    True -> "bg-green-500"
                    False -> "bg-red-500"
                  })
                  |> element.empty(),
                html.h1()
                  |> attribute.class("text-lg font-semibold text-gray-800")
                  |> element.text_content(agent_info.name),
              ]),
          ]),
        // Messages container
        html.div()
          |> attribute.id(msgs_container_id)
          |> attribute.class("flex-1 overflow-y-auto p-4 space-y-3")
          |> element.keyed({
            use chat_msg <- list.map(sorted_chat_msgs)
            #(chat_msg.id, chat_message_element(chat_msg))
          }),
        // Input form
        html.form()
          |> attribute.class("flex gap-3 p-4 bg-white border-t border-gray-200")
          |> event.on_submit(fn(_) { UserSendDraft })
          |> element.children([
            html.input()
              |> event.on_input(UserUpdateDraftContent)
              |> attribute.type_("text")
              |> attribute.value(model.draft_content)
              |> attribute.placeholder("Type your message...")
              |> attribute.class(
                "flex-1 px-4 py-3 border border-gray-300 rounded-xl focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent",
              )
              |> element.empty(),
            html.button()
              |> attribute.type_("submit")
              |> attribute.disabled(
                string.trim(model.draft_content) == ""
                || model.connected == False,
              )
              |> attribute.class(
                "px-6 py-3 bg-blue-600 text-white rounded-xl font-medium hover:bg-blue-700 transition-colors disabled:bg-gray-300 disabled:cursor-not-allowed",
              )
              |> element.text_content("Send"),
          ]),
      ])
    }
  }
}
