-module(pig_agent_try_call_ffi).

%% Safe wrapper around gleam@otp@actor:call/3 that returns
%% {ok, Result} on success or {error, nil} when the callee
%% crashes, the call times out, or any exception is raised
%% (error, exit, or throw classes — instead of panicking).

-export([try_call/3]).

try_call(Subject, Timeout, MakeMessage) ->
    try
        {ok, gleam@otp@actor:call(Subject, Timeout, MakeMessage)}
    catch
        _:_ ->
            {error, nil}
    end.
