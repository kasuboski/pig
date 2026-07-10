-module(scale_test_runtime_stats_ffi).

-export([
    get_process_count/0,
    get_total_memory_bytes/0,
    get_run_queue/0,
    monotonic_ms/0
]).

get_process_count() ->
    erlang:system_info(process_count).

get_total_memory_bytes() ->
    erlang:memory(total).

get_run_queue() ->
    erlang:statistics(run_queue).

monotonic_ms() ->
    erlang:monotonic_time(millisecond).
