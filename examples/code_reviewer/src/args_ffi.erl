-module(args_ffi).
-export([get_args/0]).

get_args() ->
    %% init:get_plain_arguments() returns a list of charlists.
    %% Convert each to a binary (Gleam string).
    Args = init:get_plain_arguments(),
    [unicode:characters_to_binary(A) || A <- Args].
