import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit
import pig_proxy/circuit_actor
import pig_proxy/config
import pig_proxy/execution
import pig_proxy/transport
import support/in_memory_transport

pub fn main() -> Nil {
  gleeunit.main()
}

// ── Fixtures ────────────────────────────────────────────────────

fn req() -> execution.ProxyRequest {
  execution.ProxyRequest(
    method: "POST",
    path: "/v1/chat/completions",
    headers: [],
    body: "{\"model\":\"m\"}",
    model: "m",
  )
}

fn openai() -> config.UpstreamTarget {
  config.openai_target("openai", "http://x/v1", "k")
}

fn ollama() -> config.UpstreamTarget {
  config.openai_target("ollama", "http://y/v1", "k2")
}

fn ok200() -> transport.TransportResponse {
  transport.Response(
    200,
    [#("content-type", "application/json")],
    bit_array.from_string(
      "{\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":3}}",
    ),
  )
}

fn status500() -> transport.TransportResponse {
  transport.Response(500, [], <<>>)
}

fn transport_error() -> transport.TransportResponse {
  transport.TransportError("boom")
}

fn exec_with(
  transport_value: transport.Transport,
  circuit: Option(process.Subject(circuit_actor.CircuitMsg)),
) -> execution.Executor {
  execution.Executor(
    transport: transport_value,
    circuit:,
    vault: None,
    retries_per_target: 1,
    upstream_timeout_ms: 1000,
    sleep: fn(_ms) { Nil },
  )
}

// ── Commit ──────────────────────────────────────────────────────

pub fn commit_on_first_success_test() {
  let assert Ok(s) =
    in_memory_transport.start([ok200()], transport.TransportError("exhausted"))
  let outcome =
    execution.orchestrate(
      exec_with(in_memory_transport.transport(s), None),
      req(),
      execution.FallbackChain([openai()]),
    )
  let assert execution.Committed(target_id:, status:, usage:, ..) = outcome
  assert target_id == "openai"
  assert status == 200
  assert usage.prompt == Some(5)
  assert usage.completion == Some(3)
}

pub fn commit_treats_client_4xx_as_a_response_test() {
  // A 4xx is a valid response to forward, not a retry/fallback trigger.
  let assert Ok(s) =
    in_memory_transport.start(
      [transport.Response(400, [], bit_array.from_string("bad request"))],
      transport.TransportError("exhausted"),
    )
  let outcome =
    execution.orchestrate(
      exec_with(in_memory_transport.transport(s), None),
      req(),
      execution.FallbackChain([openai(), ollama()]),
    )
  let assert execution.Committed(target_id:, status:, ..) = outcome
  assert target_id == "openai"
  assert status == 400
}

// ── Retry within budget ─────────────────────────────────────────

pub fn retry_within_budget_then_commit_test() {
  // Budget 1: first attempt 500 (retry), second attempt 200 (commit).
  let assert Ok(s) =
    in_memory_transport.start([status500(), ok200()], transport.TransportError("x"))
  let outcome =
    execution.orchestrate(
      exec_with(in_memory_transport.transport(s), None),
      req(),
      execution.FallbackChain([openai()]),
    )
  let assert execution.Committed(target_id:, status:, ..) = outcome
  assert target_id == "openai"
  assert status == 200
}

pub fn transport_error_retries_then_exhausts_test() {
  let assert Ok(s) =
    in_memory_transport.start(
      [transport_error(), transport_error()],
      transport.TransportError("x"),
    )
  let outcome =
    execution.orchestrate(
      exec_with(in_memory_transport.transport(s), None),
      req(),
      execution.FallbackChain([openai()]),
    )
  let assert execution.Exhausted(target_id:, reason:, ..) = outcome
  let assert Some("openai") = target_id
  assert reason == "boom"
}

// ── Fallback ────────────────────────────────────────────────────

pub fn budget_exhausted_then_fallback_commits_test() {
  // openai exhausts its budget (two 500s), then ollama commits.
  let assert Ok(c) = circuit_actor.start(1, 1_000_000)
  let assert Ok(s) =
    in_memory_transport.start(
      [status500(), status500(), ok200()],
      transport.TransportError("x"),
    )
  let outcome =
    execution.orchestrate(
      exec_with(in_memory_transport.transport(s), Some(c)),
      req(),
      execution.FallbackChain([openai(), ollama()]),
    )
  let assert execution.Committed(target_id:, status:, ..) = outcome
  assert target_id == "ollama"
  assert status == 200
  // openai recorded one failure (threshold 1) → its circuit is now open.
  assert circuit_actor.admit(c, "openai", 2000) == False
}

pub fn all_targets_exhausted_test() {
  let assert Ok(s) =
    in_memory_transport.start(
      [status500(), status500()],
      transport.TransportError("x"),
    )
  let outcome =
    execution.orchestrate(
      exec_with(in_memory_transport.transport(s), None),
      req(),
      execution.FallbackChain([openai()]),
    )
  let assert execution.Exhausted(target_id:, reason:, ..) = outcome
  let assert Some("openai") = target_id
  assert reason == "upstream_500"
}

/// When a target exhausts its budget and the rest are circuit-skipped, the
/// outcome is the prior `Exhausted` (502, last attempted target) — NOT
/// `NoTargets`, which would mask the exhaustion.
pub fn exhaustion_not_masked_by_skipped_targets_test() {
  let assert Ok(c) = circuit_actor.start(1, 1_000_000)
  circuit_actor.record_failure(c, "ollama")
  let assert Ok(s) =
    in_memory_transport.start(
      [status500(), status500()],
      transport.TransportError("x"),
    )
  let outcome =
    execution.orchestrate(
      exec_with(in_memory_transport.transport(s), Some(c)),
      req(),
      execution.FallbackChain([openai(), ollama()]),
    )
  let assert execution.Exhausted(target_id:, ..) = outcome
  let assert Some("openai") = target_id
}

// ── Circuit admission ───────────────────────────────────────────

pub fn open_circuit_target_is_skipped_test() {
  let assert Ok(c) = circuit_actor.start(1, 1_000_000)
  circuit_actor.record_failure(c, "openai")
  // Only one response scripted: openai is skipped, ollama uses it.
  let assert Ok(s) =
    in_memory_transport.start([ok200()], transport.TransportError("x"))
  let outcome =
    execution.orchestrate(
      exec_with(in_memory_transport.transport(s), Some(c)),
      req(),
      execution.FallbackChain([openai(), ollama()]),
    )
  let assert execution.Committed(target_id:, ..) = outcome
  assert target_id == "ollama"
}

pub fn empty_chain_returns_no_targets_test() {
  let assert Ok(s) =
    in_memory_transport.start([], transport.TransportError("x"))
  let outcome =
    execution.orchestrate(
      exec_with(in_memory_transport.transport(s), None),
      req(),
      execution.FallbackChain([]),
    )
  let assert execution.NoTargets(..) = outcome
}

// ── Streaming fixtures ─────────────────────────────────────────

fn bin(s: String) -> BitArray {
  bit_array.from_string(s)
}

fn committed(
  status: Int,
  chunks: List(BitArray),
  terminal: in_memory_transport.StreamTerminal,
) -> in_memory_transport.StreamScript {
  in_memory_transport.CommitStream(status:, headers: [], chunks:, terminal:)
}

fn rejected(status: Int, body: BitArray) -> in_memory_transport.StreamScript {
  in_memory_transport.RejectStream(status:, headers: [], body:)
}

fn failed(reason: String) -> in_memory_transport.StreamScript {
  in_memory_transport.FailStream(reason)
}

// ── Streaming: commit ──────────────────────────────────────────

pub fn stream_commits_on_committed_head_test() {
  let assert Ok(s) =
    in_memory_transport.start_stream(
      [committed(200, [bin("data: hi\n\n")], in_memory_transport.StreamDone)],
      failed("exhausted"),
    )
  let outcome =
    execution.orchestrate_stream(
      exec_with(in_memory_transport.transport(s), None),
      req(),
      execution.FallbackChain([openai()]),
    )
  let assert execution.CommittedStream(target_id:, status:, ..) = outcome
  assert target_id == "openai"
  assert status == 200
}

pub fn stream_non_retryable_rejected_is_forwarded_test() {
  // A 400 head on a stream is a valid response to forward, not a retry.
  let assert Ok(s) =
    in_memory_transport.start_stream(
      [rejected(400, bin("bad request"))],
      failed("exhausted"),
    )
  let outcome =
    execution.orchestrate_stream(
      exec_with(in_memory_transport.transport(s), None),
      req(),
      execution.FallbackChain([openai(), ollama()]),
    )
  let assert execution.Committed(target_id:, status:, body:, ..) = outcome
  assert target_id == "openai"
  assert status == 400
  assert body == bin("bad request")
}

// ── Streaming: retry within budget ─────────────────────────────

pub fn stream_retries_then_commits_test() {
  // Budget 1: first attempt 500 (retry), second attempt 200 (commit).
  let assert Ok(s) =
    in_memory_transport.start_stream(
      [
        rejected(500, <<>>),
        committed(200, [bin("data: ok\n\n")], in_memory_transport.StreamDone),
      ],
      failed("exhausted"),
    )
  let outcome =
    execution.orchestrate_stream(
      exec_with(in_memory_transport.transport(s), None),
      req(),
      execution.FallbackChain([openai()]),
    )
  let assert execution.CommittedStream(target_id:, status:, ..) = outcome
  assert target_id == "openai"
  assert status == 200
}

pub fn stream_failure_retries_then_exhausts_test() {
  let assert Ok(s) =
    in_memory_transport.start_stream(
      [failed("boom"), failed("boom")],
      failed("x"),
    )
  let outcome =
    execution.orchestrate_stream(
      exec_with(in_memory_transport.transport(s), None),
      req(),
      execution.FallbackChain([openai()]),
    )
  let assert execution.Exhausted(target_id:, reason:, ..) = outcome
  let assert Some("openai") = target_id
  assert reason == "boom"
}

// ── Streaming: fallback ────────────────────────────────────────

pub fn stream_budget_exhausted_then_fallback_commits_test() {
  // openai exhausts its budget (two 500s), then ollama commits.
  let assert Ok(c) = circuit_actor.start(1, 1_000_000)
  let assert Ok(s) =
    in_memory_transport.start_stream(
      [
        rejected(500, <<>>),
        rejected(500, <<>>),
        committed(200, [bin("data: ok\n\n")], in_memory_transport.StreamDone),
      ],
      failed("x"),
    )
  let outcome =
    execution.orchestrate_stream(
      exec_with(in_memory_transport.transport(s), Some(c)),
      req(),
      execution.FallbackChain([openai(), ollama()]),
    )
  let assert execution.CommittedStream(target_id:, status:, ..) = outcome
  assert target_id == "ollama"
  assert status == 200
  // openai recorded one failure (threshold 1) → its circuit is now open.
  assert circuit_actor.admit(c, "openai", 2000) == False
}

pub fn stream_open_circuit_target_is_skipped_test() {
  let assert Ok(c) = circuit_actor.start(1, 1_000_000)
  circuit_actor.record_failure(c, "openai")
  // Only one script: openai is skipped, ollama uses it.
  let assert Ok(s) =
    in_memory_transport.start_stream(
      [committed(200, [bin("data: ok\n\n")], in_memory_transport.StreamDone)],
      failed("x"),
    )
  let outcome =
    execution.orchestrate_stream(
      exec_with(in_memory_transport.transport(s), Some(c)),
      req(),
      execution.FallbackChain([openai(), ollama()]),
    )
  let assert execution.CommittedStream(target_id:, ..) = outcome
  assert target_id == "ollama"
}

pub fn stream_empty_chain_returns_no_targets_test() {
  let assert Ok(s) =
    in_memory_transport.start_stream([], failed("x"))
  let outcome =
    execution.orchestrate_stream(
      exec_with(in_memory_transport.transport(s), None),
      req(),
      execution.FallbackChain([]),
    )
  let assert execution.NoTargets(..) = outcome
}

// ── Streaming: relay forwarding (phase B) ───────────────────────

pub fn committed_stream_relay_forwards_chunks_when_started_test() {
  // Once committed, the relay forwards every byte (then the terminal) to
  // the subject named in `StartRelay` — the contract the mist loop relies on.
  let assert Ok(s) =
    in_memory_transport.start_stream(
      [
        committed(
          200,
          [bin("data: a\n\n"), bin("data: b\n\n")],
          in_memory_transport.StreamDone,
        ),
      ],
      failed("x"),
    )
  let outcome =
    execution.orchestrate_stream(
      exec_with(in_memory_transport.transport(s), None),
      req(),
      execution.FallbackChain([openai()]),
    )
  let assert execution.CommittedStream(run:, ..) = outcome

  let fwd = process.new_subject()
  process.send(run, transport.StartRelay(forward: fwd))

  let received = drain(fwd, 3)
  let assert [transport.RelayChunk(a), transport.RelayChunk(b), transport.RelayDone] =
    received
  assert a == bin("data: a\n\n")
  assert b == bin("data: b\n\n")
}

/// Collect up to `count` messages from a subject (1s each), returning what
/// arrived in order. Used to observe the relay's forwarded stream.
fn drain(
  subject: process.Subject(transport.StreamRelayMsg),
  count: Int,
) -> List(transport.StreamRelayMsg) {
  drain_loop(subject, count, [])
}

fn drain_loop(subject, count, acc) {
  case count <= 0 {
    True -> list.reverse(acc)
    False ->
      case process.receive(subject, 1000) {
        Ok(msg) -> drain_loop(subject, count - 1, [msg, ..acc])
        Error(Nil) -> list.reverse(acc)
      }
  }
}
