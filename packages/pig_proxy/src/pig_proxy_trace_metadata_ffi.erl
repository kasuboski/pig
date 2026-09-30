-module(pig_proxy_trace_metadata_ffi).
-export([new/0, push/2, finish/1]).

%% Rev bytes, retained count, oversized, consecutive line endings, last CR.
new() -> {[], 0, false, 0, false}.

push(State, Chunk) when is_binary(Chunk) -> scan(Chunk, State, []);
push(_, _) -> {new(), []}.

scan(<<>>, State, Frames) -> {State, lists:reverse(Frames)};
scan(<<Byte, Rest/binary>>, {Rev, Size, Skip, Lines, CR}, Frames) ->
    IsEnding = Byte =:= 10 orelse Byte =:= 13,
    NextLines = case {Byte, CR, IsEnding} of
        {10, true, _} -> Lines;
        {_, _, true} -> Lines + 1;
        _ -> 0
    end,
    case NextLines >= 2 of
        true ->
            NextFrames = case Skip of
                true -> Frames;
                false -> add_frame(Rev, Frames)
            end,
            %% Preserve CR so the LF of a CRLF delimiter is consumed.
            scan_after_delimiter(Rest, NextFrames, Byte =:= 13);
        false ->
            NextSkip = Skip orelse Size >= 65536,
            NextRev = case NextSkip of true -> []; false -> [Byte | Rev] end,
            scan(Rest, {NextRev, min(Size + 1, 65536), NextSkip,
                        NextLines, Byte =:= 13}, Frames)
    end.

scan_after_delimiter(<<10, Rest/binary>>, Frames, true) -> scan(Rest, new(), Frames);
scan_after_delimiter(Rest, Frames, _) -> scan(Rest, new(), Frames).

add_frame([], Frames) -> Frames;
add_frame(Rev, Frames) ->
    Bin = list_to_binary(lists:reverse(Rev)),
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Valid when is_binary(Valid) -> [Valid | Frames];
        _ -> Frames
    end.

finish({_, _, true, _, _}) -> [];
finish({Rev, _, _, _, _}) -> add_frame(Rev, []).
