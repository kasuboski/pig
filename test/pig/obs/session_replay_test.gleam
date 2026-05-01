//// Session replay tests — JSONL → List(Message) reconstruction.
////
//// Tests verify that replay() reads a JSONL file and reconstructs
//// the conversation history accurately.

import gleeunit
import gleeunit/should
import gleam/list
import gleam/string
import pig/ai/message.{User, Assistant, Tool}
import pig/obs/session
import simplifile
import temporary

pub fn main() {
  gleeunit.main()
}

// ── Test Helpers ──────────────────────────────────────────────────────

fn with_temp_file(
  name: String,
  run test_fn: fn(String) -> a,
) -> a {
  let tmp =
    temporary.file()
    |> temporary.with_prefix("pig_replay_" <> name <> "_")
    |> temporary.with_suffix(".jsonl")
  let assert Ok(result) = temporary.create(tmp, test_fn)
  result
}

fn write_jsonl(path: String, lines: List(String)) -> Nil {
  let content = string.join(lines, "\n")
  let assert Ok(Nil) = simplifile.write(path, content <> "\n")
  Nil
}

// ── Replay Tests ──────────────────────────────────────────────────────

pub fn replay_empty_file_returns_empty_list_test() {
  use path <- with_temp_file("empty")
  let assert Ok(Nil) = simplifile.write(path, "")
  let result = session.replay(path)
  should.equal(result, Ok([]))
}

pub fn replay_file_not_found_returns_error_test() {
  let result = session.replay("/nonexistent/path/session.jsonl")
  should.be_error(result)
}

pub fn replay_single_inference_reconstructs_messages_test() {
  use path <- with_temp_file("single_inference")
  write_jsonl(path, [
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_started\",\"model\":\"gpt-4\",\"message_count\":1}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_completed\",\"duration_ms\":100,\"message\":{\"role\":\"assistant\",\"content\":\"Hello!\",\"tool_calls\":[]},\"input_messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}",
  ])
  let assert Ok(messages) = session.replay(path)
  // Should have: input_messages + assistant message = [User("Hi"), Assistant("Hello!")]
  should.equal(list.length(messages), 2)
  let assert [User(content: hi), Assistant(content: hello, ..)] = messages
  should.equal(hi, "Hi")
  should.equal(hello, "Hello!")
}

pub fn replay_with_tool_calls_reconstructs_full_history_test() {
  use path <- with_temp_file("tool_calls")
  write_jsonl(path, [
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_started\",\"model\":\"gpt-4\",\"message_count\":1}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_completed\",\"duration_ms\":50,\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c1\",\"name\":\"echo\",\"arguments\":\"{\\\"msg\\\":\\\"hello\\\"}\"}]},\"input_messages\":[{\"role\":\"user\",\"content\":\"use echo\"}]}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"tool_started\",\"tool_call\":{\"id\":\"c1\",\"name\":\"echo\",\"arguments\":\"{\\\"msg\\\":\\\"hello\\\"}\"}}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"tool_executed\",\"duration_ms\":5,\"tool_call\":{\"id\":\"c1\",\"name\":\"echo\",\"arguments\":\"{\\\"msg\\\":\\\"hello\\\"}\"},\"result\":\"{\\\"echo\\\":\\\"hello\\\"}\"}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_started\",\"model\":\"gpt-4\",\"message_count\":4}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_completed\",\"duration_ms\":80,\"message\":{\"role\":\"assistant\",\"content\":\"Done!\",\"tool_calls\":[]},\"input_messages\":[{\"role\":\"user\",\"content\":\"use echo\"},{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c1\",\"name\":\"echo\",\"arguments\":\"{\\\"msg\\\":\\\"hello\\\"}\"}]},{\"role\":\"tool\",\"tool_call_id\":\"c1\",\"content\":\"{\\\"echo\\\":\\\"hello\\\"}\"}]}",
  ])
  let assert Ok(messages) = session.replay(path)
  // Should have: input_messages from last inference + final assistant = 4 messages
  should.equal(list.length(messages), 4)
  let assert [User(content: use_echo), Assistant(content: "", tool_calls: [_tc], ..), Tool(tool_call_id: tc_id, content: _tool_content), Assistant(content: done, ..)] = messages
  should.equal(use_echo, "use echo")
  should.equal(done, "Done!")
  should.equal(tc_id, "c1")
}

/// Replay handles tool_blocked events after last inference (crash recovery).
pub fn replay_with_blocked_tool_after_last_inference_test() {
  use path <- with_temp_file("blocked_tool")
  write_jsonl(path, [
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_started\",\"model\":\"gpt-4\",\"message_count\":1}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"inference_completed\",\"duration_ms\":50,\"message\":{\"role\":\"assistant\",\"content\":\"\",\"tool_calls\":[{\"id\":\"c1\",\"name\":\"bash\",\"arguments\":\"{}\"}]},\"input_messages\":[{\"role\":\"user\",\"content\":\"rm -rf /\"}]}",
    "{\"ts\":\"2024-01-01T00:00:00Z\",\"event\":\"tool_blocked\",\"tool_call\":{\"id\":\"c1\",\"name\":\"bash\",\"arguments\":\"{}\"},\"hook_name\":\"safety-guard\",\"reason\":\"dangerous command\"}",
  ])
  let assert Ok(messages) = session.replay(path)
  // Should have: input_messages from last inference + assistant + blocked tool message = 3
  should.equal(list.length(messages), 3)
  let assert [User(content: prompt), Assistant(content: "", tool_calls: [_tc], ..), Tool(tool_call_id: id, content: blocked_content)] = messages
  should.equal(prompt, "rm -rf /")
  should.equal(id, "c1")
  // Blocked tool content should reconstruct from hook_name + reason
  should.equal(blocked_content, "Tool blocked by 'safety-guard': dangerous command")
}
