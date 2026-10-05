-module(pig_proxy_server_ffi).
-export([stop_listener/1]).

stop_listener(Pid) ->
    unlink(Pid),
    Monitor = erlang:monitor(process, Pid),
    try
        try gen_server:stop(Pid, shutdown, 5000)
        catch
            exit:noproc -> ok;
            exit:normal -> ok;
            exit:shutdown -> ok;
            exit:timeout -> exit(Pid, kill);
            exit:{timeout, _} -> exit(Pid, kill)
        end,
        receive
            {'DOWN', Monitor, process, Pid, _} -> nil
        after 1000 ->
            exit(Pid, kill),
            receive {'DOWN', Monitor, process, Pid, _} -> nil end
        end
    after
        erlang:demonitor(Monitor, [flush])
    end.
