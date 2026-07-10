//// Runtime statistics from the BEAM VM.
//// Wraps Erlang FFI calls for process count, memory, scheduler run queue.

pub type RuntimeMetrics {
  RuntimeMetrics(
    beam_processes: Int,
    total_memory_bytes: Int,
    run_queue: Int,
    monotonic_ms: Int,
  )
}

@external(erlang, "scale_test_runtime_stats_ffi", "get_process_count")
pub fn get_process_count() -> Int

@external(erlang, "scale_test_runtime_stats_ffi", "get_total_memory_bytes")
pub fn get_total_memory_bytes() -> Int

@external(erlang, "scale_test_runtime_stats_ffi", "get_run_queue")
pub fn get_run_queue() -> Int

@external(erlang, "scale_test_runtime_stats_ffi", "monotonic_ms")
pub fn monotonic_ms() -> Int

/// Sample all runtime metrics at once.
pub fn sample() -> RuntimeMetrics {
  RuntimeMetrics(
    beam_processes: get_process_count(),
    total_memory_bytes: get_total_memory_bytes(),
    run_queue: get_run_queue(),
    monotonic_ms: monotonic_ms(),
  )
}
