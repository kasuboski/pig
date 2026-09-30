-module(pig_proxy_runtime_ffi).
-export([stop_supervised/1]).

stop_supervised(Pid) ->
    unlink(Pid),
    Monitor = erlang:monitor(process, Pid),
    try
        %% Stopping the root prevents permanent named children from restarting.
        %% proc_lib's synchronous stop waits for supervisor termination callbacks.
        try gen_server:stop(Pid, shutdown, infinity)
        catch
            exit:noproc -> ok;
            exit:normal -> ok;
            exit:shutdown -> ok
        end,
        receive {'DOWN', Monitor, process, Pid, _} -> nil end
    after
        erlang:demonitor(Monitor, [flush])
    end.
