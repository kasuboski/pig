import gleeunit
import shared

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn assistant_delta_round_trips_over_the_server_protocol_test() {
  let message = shared.ServerAssistantDelta("elf", "reply-1", "hello")
  let encoded = shared.encode_server_message(message)
  let assert Ok(decoded) = shared.decode_server_message(encoded)
  assert decoded == message
}

pub fn rejected_pending_message_round_trips_over_the_server_protocol_test() {
  let message = shared.ServerRemoveChatMessage("elf", "pending-user-1")
  let encoded = shared.encode_server_message(message)
  let assert Ok(decoded) = shared.decode_server_message(encoded)
  assert decoded == message
}

pub fn assistant_delta_accumulates_on_one_placeholder_test() {
  let placeholder = shared.new_streaming_ai_chat_msg()
  let first = shared.append_assistant_delta(placeholder, "hello")
  let second = shared.append_assistant_delta(first, " world")
  let finalized = shared.finalize_assistant_message(second, "canonical")

  assert second.id == placeholder.id
  assert second.content == "hello world"
  assert second.status == shared.Streaming
  assert finalized.id == placeholder.id
  assert finalized.content == "canonical"
  assert finalized.status == shared.Received
  assert finalized.is_ai
}

pub fn streaming_status_is_encoded_in_chat_messages_test() {
  let message = shared.new_streaming_ai_chat_msg()
  let assert Ok(shared.ServerUpsertChatMessages(_, [decoded])) =
    shared.decode_server_message(
      shared.encode_server_message(
        shared.ServerUpsertChatMessages("elf", [message]),
      ),
    )
  assert decoded.status == shared.Streaming
}
