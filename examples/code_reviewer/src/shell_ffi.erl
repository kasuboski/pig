-module(shell_ffi).
-export([run/1]).

run(Cmd) ->
    %% os:cmd expects a charlist (iolist), not a binary.
    case unicode:characters_to_list(Cmd) of
        CmdList when is_list(CmdList) ->
            Output = os:cmd(CmdList),
            case unicode:characters_to_binary(Output) of
                Bin when is_binary(Bin) -> {ok, Bin};
                {error, _, _} -> {error, nil};
                {incomplete, _, _} -> {error, nil}
            end;
        {error, _, _} ->
            {error, nil};
        {incomplete, _, _} ->
            {error, nil}
    end.
