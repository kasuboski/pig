import gleam/dynamic/decode as dyn_decode
import gleam/json
import gleam/string

import birl
import gluid

// ─── Agent Types ──────────────────────────────────────────────

pub type AgentId =
  String

pub type AgentInfo {
  AgentInfo(id: AgentId, name: String, description: String)
}

// ─── Chat Types ───────────────────────────────────────────────

pub type ChatMessageId =
  String

pub type MessageStatus {
  ClientError
  ServerError
  Sent
  Received
  Sending
}

pub type ChatMessage {
  ChatMessage(
    id: ChatMessageId,
    content: String,
    status: MessageStatus,
    sent_at: birl.Time,
    is_ai: Bool,
  )
}

// ─── Client → Server Messages ─────────────────────────────────

pub type ClientMessage {
  SelectAgent(AgentId)
  UserSendChatMessage(AgentId, ChatMessage)
  FetchChatMessages(AgentId)
}

// ─── Server → Client Messages ─────────────────────────────────

pub type ServerMessage {
  AgentSelected(AgentId, List(ChatMessage))
  ServerUpsertChatMessages(AgentId, List(ChatMessage))
  AgentList(List(AgentInfo))
}

// ─── Constructor Helpers ──────────────────────────────────────

pub fn new_chat_msg(content content: String, status status: MessageStatus) {
  ChatMessage(
    id: gluid.guidv4() |> string.lowercase(),
    content:,
    status:,
    sent_at: birl.utc_now(),
    is_ai: False,
  )
}

pub fn new_ai_chat_msg(content content: String) {
  ChatMessage(
    id: gluid.guidv4() |> string.lowercase(),
    content:,
    status: Received,
    sent_at: birl.utc_now(),
    is_ai: True,
  )
}

// ─── Status Helpers ───────────────────────────────────────────

pub fn status_string(status: MessageStatus) -> String {
  case status {
    ClientError -> "Client Error"
    ServerError -> "Server Error"
    Sent -> "Sent"
    Received -> "Received"
    Sending -> "Sending"
  }
}

fn encode_status(status: MessageStatus) -> Int {
  case status {
    ClientError -> 0
    ServerError -> 1
    Sent -> 2
    Received -> 3
    Sending -> 4
  }
}

fn status_decoder() -> dyn_decode.Decoder(MessageStatus) {
  dyn_decode.then(dyn_decode.int, fn(decoded) {
    case decoded {
      0 -> dyn_decode.success(ClientError)
      1 -> dyn_decode.success(ServerError)
      2 -> dyn_decode.success(Sent)
      3 -> dyn_decode.success(Received)
      4 -> dyn_decode.success(Sending)
      _ -> dyn_decode.failure(ClientError, "MessageStatus")
    }
  })
}

// ─── ChatMessage Encode / Decode ──────────────────────────────

pub fn encode_chat_message(message: ChatMessage) -> String {
  chat_message_to_json(message) |> json.to_string
}

fn chat_message_to_json(message: ChatMessage) -> json.Json {
  json.object([
    #("id", json.string(message.id)),
    #("content", json.string(message.content)),
    #("status", json.int(encode_status(message.status))),
    #("sent_at", json.int(birl.to_unix(message.sent_at))),
    #("is_ai", json.bool(message.is_ai)),
  ])
}

fn chat_message_decoder() -> dyn_decode.Decoder(ChatMessage) {
  use id <- dyn_decode.field("id", dyn_decode.string)
  use content <- dyn_decode.field("content", dyn_decode.string)
  use status <- dyn_decode.field("status", status_decoder())
  use sent_at_unix <- dyn_decode.field("sent_at", dyn_decode.int)
  use is_ai <- dyn_decode.field("is_ai", dyn_decode.bool)
  let sent_at = birl.from_unix(sent_at_unix)
  dyn_decode.success(ChatMessage(id:, content:, status:, sent_at:, is_ai:))
}

// ─── AgentInfo Decode ─────────────────────────────────────────

fn agent_info_decoder() -> dyn_decode.Decoder(AgentInfo) {
  use id <- dyn_decode.field("id", dyn_decode.string)
  use name <- dyn_decode.field("name", dyn_decode.string)
  use description <- dyn_decode.field("description", dyn_decode.string)
  dyn_decode.success(AgentInfo(id:, name:, description:))
}

// ─── ClientMessage Encode / Decode ────────────────────────────

pub fn encode_client_message(msg: ClientMessage) -> String {
  case msg {
    SelectAgent(agent_id) -> [
      json.int(0),
      json.string(agent_id),
    ]
    UserSendChatMessage(agent_id, chat_msg) -> [
      json.int(1),
      json.string(agent_id),
      chat_message_to_json(chat_msg),
    ]
    FetchChatMessages(agent_id) -> [
      json.int(2),
      json.string(agent_id),
    ]
  }
  |> json.preprocessed_array
  |> json.to_string
}

pub fn decode_client_message(str_msg: String) {
  json.parse(from: str_msg, using: client_message_decoder())
}

fn client_message_decoder() -> dyn_decode.Decoder(ClientMessage) {
  use id <- dyn_decode.field(0, dyn_decode.int)
  case id {
    0 -> {
      use agent_id <- dyn_decode.field(1, dyn_decode.string)
      dyn_decode.success(SelectAgent(agent_id))
    }
    1 -> {
      use agent_id <- dyn_decode.field(1, dyn_decode.string)
      use chat_msg <- dyn_decode.field(2, chat_message_decoder())
      dyn_decode.success(UserSendChatMessage(agent_id, chat_msg))
    }
    2 -> {
      use agent_id <- dyn_decode.field(1, dyn_decode.string)
      dyn_decode.success(FetchChatMessages(agent_id))
    }
    _ -> dyn_decode.failure(SelectAgent(""), "ClientMessage")
  }
}

// ─── ServerMessage Encode / Decode ────────────────────────────

pub fn encode_server_message(msg: ServerMessage) -> String {
  case msg {
    AgentSelected(agent_id, messages) -> [
      json.int(0),
      json.string(agent_id),
      json.array(messages, chat_message_to_json),
    ]
    ServerUpsertChatMessages(agent_id, messages) -> [
      json.int(1),
      json.string(agent_id),
      json.array(messages, chat_message_to_json),
    ]
    AgentList(agents) -> [
      json.int(2),
      json.array(agents, fn(a) {
        json.object([
          #("id", json.string(a.id)),
          #("name", json.string(a.name)),
          #("description", json.string(a.description)),
        ])
      }),
    ]
  }
  |> json.preprocessed_array
  |> json.to_string
}

pub fn decode_server_message(str_msg: String) {
  json.parse(from: str_msg, using: server_message_decoder())
}

fn server_message_decoder() -> dyn_decode.Decoder(ServerMessage) {
  use id <- dyn_decode.field(0, dyn_decode.int)
  case id {
    0 -> {
      use agent_id <- dyn_decode.field(1, dyn_decode.string)
      use messages <- dyn_decode.field(
        2,
        dyn_decode.list(chat_message_decoder()),
      )
      dyn_decode.success(AgentSelected(agent_id, messages))
    }
    1 -> {
      use agent_id <- dyn_decode.field(1, dyn_decode.string)
      use messages <- dyn_decode.field(
        2,
        dyn_decode.list(chat_message_decoder()),
      )
      dyn_decode.success(ServerUpsertChatMessages(agent_id, messages))
    }
    2 -> {
      use agents <- dyn_decode.field(1, dyn_decode.list(agent_info_decoder()))
      dyn_decode.success(AgentList(agents))
    }
    _ -> dyn_decode.failure(AgentList([]), "ServerMessage")
  }
}
