-module(pig_proxy_trace_metadata_ffi).
-export([new/0, push/2, finish/1, retained_bytes/1]).

-define(MAX_EVENT_BYTES, 4194304).
-define(BLOCK_BYTES, 16384).

%% Pending reversed byte list (at most one block), completed binary blocks,
%% retained frame bytes, oversized flag, consecutive line endings, last CR.
new() -> {[], [], 0, 0, false, 0, false}.

push(State, Chunk) when is_binary(Chunk) -> scan(Chunk, State, []);
push(_, _) -> {new(), []}.

scan(<<>>, State, Frames) -> {State, lists:reverse(Frames)};
scan(<<Byte, Rest/binary>>, {Pending, Blocks, BlockSize, Size, Skip, Lines, CR}, Frames) ->
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
                false -> add_frame(Pending, Blocks, Frames)
            end,
            %% Preserve CR so the LF of a CRLF delimiter is consumed.
            scan_after_delimiter(Rest, NextFrames, Byte =:= 13);
        false ->
            NextSkip = Skip orelse Size >= ?MAX_EVENT_BYTES,
            case NextSkip of
                true ->
                    scan(Rest, {[], [], 0, ?MAX_EVENT_BYTES, true,
                                NextLines, Byte =:= 13}, Frames);
                false ->
                    NextPending = [Byte | Pending],
                    NextBlockSize = BlockSize + 1,
                    case NextBlockSize >= ?BLOCK_BYTES of
                        true ->
                            Block = list_to_binary(lists:reverse(NextPending)),
                            scan(Rest, {[], [Block | Blocks], 0, Size + 1,
                                        false, NextLines, Byte =:= 13}, Frames);
                        false ->
                            scan(Rest, {NextPending, Blocks, NextBlockSize,
                                        Size + 1, false, NextLines, Byte =:= 13}, Frames)
                    end
            end
    end.

scan_after_delimiter(<<10, Rest/binary>>, Frames, true) -> scan(Rest, new(), Frames);
scan_after_delimiter(Rest, Frames, _) -> scan(Rest, new(), Frames).

add_frame([], [], Frames) -> Frames;
add_frame(Pending, Blocks, Frames) ->
    Tail = case Pending of
        [] -> [];
        _ -> [list_to_binary(lists:reverse(Pending))]
    end,
    Bin = iolist_to_binary(lists:reverse(Blocks) ++ Tail),
    case unicode:characters_to_binary(Bin, utf8, utf8) of
        Valid when is_binary(Valid) -> [Valid | Frames];
        _ -> Frames
    end.

finish({_, _, _, _, true, _, _}) -> [];
finish({Pending, Blocks, _, _, _, _, _}) -> add_frame(Pending, Blocks, []).

retained_bytes({_, _, _, Size, Skip, _, _}) ->
    case Skip of
        true -> 0;
        false -> Size
    end.
