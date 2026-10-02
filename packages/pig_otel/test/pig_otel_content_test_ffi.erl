-module(pig_otel_content_test_ffi).
-export([scenario/1, golden/1, normalize/1, chunks/2, partitions/2,
         validate/2, check_validation_cases/1, read_fixture/1]).

read_fixture(Path) ->
    case file:read_file(Path) of
        {ok, Bytes} -> {ok, Bytes};
        {error, _} -> {error, nil}
    end.

scenario(Json) ->
    M = json:decode(Json),
    Api = case maps:get(<<"api">>, M) of
        <<"chat">> -> chat_completions;
        <<"responses">> -> responses;
        <<"custom">> -> custom
    end,
    Direction = case maps:get(<<"direction">>, M, <<"output">>) of
        <<"input">> -> input;
        <<"output">> -> output
    end,
    {scenario, Api, Direction, maps:get(<<"source">>, M, 65536),
     maps:get(<<"budget">>, M, 16384), maps:get(<<"keys">>, M, []),
     maps:get(<<"literals">>, M, []), maps:get(<<"complete">>, M, true)}.

golden(Json) ->
    [{K, case V of B when is_binary(B) -> B; _ -> encode(V) end}
     || {K, V} <- maps:to_list(json:decode(Json))].

normalize(B) ->
    try encode(json:decode(B)) catch _:_ -> B end.
encode(V) -> iolist_to_binary(json:encode(V)).

chunks(<<>>, _) -> [];
chunks(B, N) when byte_size(B) =< N -> [B];
chunks(B, N) -> <<Head:N/binary, Rest/binary>> = B, [Head | chunks(Rest, N)].

partitions(Body, Settings) ->
    Usual = [chunks(Body, N) || N <- [1, 2, 3, 7, 31, 65536]],
    case maps:get(<<"all_splits">>, json:decode(Settings), false) of
        false -> Usual;
        true -> Usual ++ [[binary:part(Body, 0, N),
                          binary:part(Body, N, byte_size(Body) - N)]
                         || N <- lists:seq(0, byte_size(Body))]
    end.

%% Explicit checks for the adapter's supported typed subset, NOT a draft-7
%% schema validator. Validate actual values, independently of golden equality.
validate(Pairs, Settings) ->
    try
        Values = [begin
            true = lists:member(K, [<<"gen_ai.input.messages">>, <<"gen_ai.output.messages">>,
                                    <<"gen_ai.system_instructions">>, <<"gen_ai.tool.definitions">>]),
            V = json:decode(B),
            true = is_list(V),
            lists:foreach(fun(X) -> shape(K, X) end, V),
            {K, V}
        end || {<<"gen_ai.", _/binary>> = K, B} <- Pairs],
        Parts = lists:append([maps:get(<<"parts">>, M) ||
            {K, Messages} <- Values,
            K =:= <<"gen_ai.input.messages">> orelse K =:= <<"gen_ai.output.messages">>,
            M <- Messages]),
        Checks = maps:get(<<"assertions">>, json:decode(Settings), #{}),
        lists:foreach(fun(P) -> true = lists:member(P, Parts) end,
                      maps:get(<<"parts">>, Checks, [])),
        lists:foreach(fun(B) ->
            true = lists:all(fun({_K, V}) -> binary:match(V, B) =:= nomatch end, Pairs)
        end, maps:get(<<"absent">>, Checks, [])),
        true
    catch _:_ -> false end.

check_validation_cases(Json) ->
    lists:all(fun(C) ->
        validate(golden(encode(maps:get(<<"attributes">>, C))),
                 encode(maps:get(<<"settings">>, C, #{}))) =:= maps:get(<<"valid">>, C)
    end, json:decode(Json)).

shape(<<"gen_ai.system_instructions">>, P) -> text_shape(P);
shape(<<"gen_ai.tool.definitions">>, D) ->
    fields(D, [<<"type">>, <<"name">>]),
    <<"function">> = maps:get(<<"type">>, D),
    identity_shape(maps:get(<<"name">>, D));
shape(K, M) when K =:= <<"gen_ai.input.messages">>; K =:= <<"gen_ai.output.messages">> ->
    case K of
        <<"gen_ai.output.messages">> ->
            fields(M, [<<"role">>, <<"parts">>, <<"finish_reason">>]),
            <<"assistant">> = maps:get(<<"role">>, M),
            true = lists:member(maps:get(<<"finish_reason">>, M),
                                [<<"stop">>, <<"length">>, <<"content_filter">>, <<"tool_call">>]);
        _ -> fields(M, [<<"role">>, <<"parts">>])
    end,
    true = lists:member(maps:get(<<"role">>, M),
                        [<<"user">>, <<"assistant">>, <<"system">>, <<"developer">>, <<"tool">>]),
    true = is_list(maps:get(<<"parts">>, M)),
    lists:foreach(fun part_shape/1, maps:get(<<"parts">>, M)).

part_shape(#{<<"type">> := <<"text">>} = P) -> text_shape(P);
part_shape(#{<<"type">> := <<"tool_call">>} = P) ->
    fields(P, [<<"type">>, <<"id">>, <<"name">>, <<"arguments">>]),
    identity_shape(maps:get(<<"id">>, P)),
    identity_shape(maps:get(<<"name">>, P));
part_shape(#{<<"type">> := <<"tool_call_response">>} = P) ->
    fields(P, [<<"type">>, <<"id">>, <<"response">>]),
    identity_shape(maps:get(<<"id">>, P)).

text_shape(P) ->
    fields(P, [<<"type">>, <<"content">>]),
    <<"text">> = maps:get(<<"type">>, P),
    true = is_binary(maps:get(<<"content">>, P)).

identity_shape(B) -> true = is_binary(B) andalso byte_size(B) > 0 andalso byte_size(B) =< 256.
fields(M, Keys) -> true = lists:sort(maps:keys(M)) =:= lists:sort(Keys).
