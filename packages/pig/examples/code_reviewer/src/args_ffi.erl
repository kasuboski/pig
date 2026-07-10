-module(args_ffi).
-export([get_args/0]).

get_args() ->
    %% init:get_plain_arguments() returns a list of charlists.
    %% Convert each to a binary (Gleam string), handling unicode errors.
    Args = init:get_plain_arguments(),
    [to_binary(A) || A <- Args].

to_binary(Charlist) ->
    case unicode:characters_to_binary(Charlist) of
        Bin when is_binary(Bin) -> Bin;
        {error, _, _} -> <<>>;
        {incomplete, _, _} -> <<>>
    end.
