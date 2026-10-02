-module(pig_proxy_trace_death_test_ffi).
-export([wait_retired/2, shutdown_supervisor/1]).

wait_retired(Subject, Action) ->
    {ok, Pid} = 'gleam@erlang@process':subject_owner(Subject),
    Monitor = erlang:monitor(process, Pid),
    Action(),
    receive {'DOWN', Monitor, process, Pid, _} -> nil
    after 5000 -> erlang:error(retirement_ack_timeout)
    end.

shutdown_supervisor(Pid) ->
    unlink(Pid),
    Monitor = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', Monitor, process, Pid, _} -> nil
    after 5000 -> erlang:error(supervisor_cleanup_timeout)
    end.
