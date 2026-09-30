-module(pig_proxy_runtime_test_ffi).
-export([wait_tree_stopped/2]).

wait_tree_stopped(Root, Stop) ->
    %% Snapshot and monitor the real static root, named factory and its owners
    %% before stopping. No sleeps or PID identity assertions arrange the test.
    Monitors = [{erlang:monitor(process, Pid), Pid} || Pid <- tree(Root)],
    try
        Stop(),
        lists:foreach(fun({Ref, Pid}) ->
            receive
                {'DOWN', Ref, process, Pid, shutdown} -> ok;
                {'DOWN', Ref, process, Pid, Reason} ->
                    erlang:error({not_graceful_shutdown, Reason})
            after 5000 -> erlang:error(supervised_cleanup_ack_timeout)
            end
        end, Monitors),
        nil
    after
        lists:foreach(fun({Ref, _}) -> erlang:demonitor(Ref, [flush]) end, Monitors)
    end.

tree(Supervisor) ->
    [Supervisor | lists:flatmap(fun
        ({_, Pid, supervisor, _}) when is_pid(Pid) -> tree(Pid);
        ({_, Pid, worker, _}) when is_pid(Pid) -> [Pid]
    end, supervisor:which_children(Supervisor))].
