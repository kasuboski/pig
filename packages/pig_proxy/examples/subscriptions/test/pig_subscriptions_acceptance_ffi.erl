%% Platform primitives only; all scenarios, waits, fixtures and assertions are Gleam.
-module(pig_subscriptions_acceptance_ffi).
-export([executable/0, module_directory/0, add_paths/1, start/3,
         signal/2, close/1, free_port/0]).

executable() -> unicode:characters_to_binary(os:find_executable("erl")).
module_directory() ->
    unicode:characters_to_binary(filename:dirname(filename:absname(code:which(?MODULE)))).

add_paths(Paths) ->
    ok = code:add_paths([unicode:characters_to_list(P) || P <- Paths]),
    nil.

start(Executable, Args, Environment) ->
    Env = [{unicode:characters_to_list(Key), env_value(Value)} || {Key, Value} <- Environment],
    open_port({spawn_executable, unicode:characters_to_list(Executable)},
        [{args, [unicode:characters_to_list(Arg) || Arg <- Args]}, {env, Env},
         binary, use_stdio, stderr_to_stdout, exit_status]).

env_value({some, Value}) -> unicode:characters_to_list(Value);
env_value(none) -> false.

signal(Port, Signal) ->
    case erlang:port_info(Port, os_pid) of
        {os_pid, Pid} ->
            Flag = case Signal of term -> "TERM"; kill -> "KILL" end,
            _ = os:cmd("kill -" ++ Flag ++ " " ++ integer_to_list(Pid)),
            nil;
        undefined -> nil
    end.

close(Port) ->
    try port_close(Port) catch error:badarg -> ok end,
    nil.

free_port() ->
    {ok, Socket} = gen_tcp:listen(0, [{ip, {127,0,0,1}}, {reuseaddr, true}]),
    try
        {ok, {_, Port}} = inet:sockname(Socket),
        Port
    after gen_tcp:close(Socket) end.
