//// Shared protocol types for inter-actor communication.

import gleam/erlang/process.{type Subject}
import scale_test/grid.{type Grid, type Organism, type Position}

/// Messages the scheduler can receive.
pub type SchedulerMsg {
  /// Enqueue organisms for re-thinking, with a snapshot of the current grid
  Enqueue(decisions: List(#(Position, Organism)), grid: Grid)
  /// Change concurrency limit
  SetConcurrency(Int)
  /// Internal: an LLM batch call has completed
  LlmCompleted(
    positions: List(Position),
    results: List(#(Position, Result(String, Nil))),
  )
  /// Internal tick to process queue
  ProcessQueue
  /// Get scheduler stats (replies to the subject)
  GetStats(reply_to: Subject(SchedulerStats))
}

/// Stats from the scheduler.
pub type SchedulerStats {
  SchedulerStats(
    llm_calls: Int,
    llm_errors: Int,
    queue_depth: Int,
    in_flight: Int,
    max_concurrency: Int,
    model: String,
  )
}
