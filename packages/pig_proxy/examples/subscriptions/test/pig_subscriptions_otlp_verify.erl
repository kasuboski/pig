%% Contract over spans decoded from the actual HTTP/protobuf export.
-module(pig_subscriptions_otlp_verify).
-export([check/2]).

check(Spans, Capture) ->
    %% The pre-existing HTTP rejection checks also emit eight server spans.
    20 = length(Spans),
    Ids = [{maps:get(trace_id, S), maps:get(span_id, S)} || S <- Spans],
    20 = length(lists:usort(Ids)),
    Encoded = term_to_binary(Spans),
    lists:foreach(fun(Secret) ->
        nomatch = binary:match(Encoded, Secret)
    end, [<<"synthetic-latitude-key">>, <<"synthetic-project">>,
           <<"synthetic-zai-key">>, <<"synthetic-client-key">>,
           <<"synthetic-client-api-key">>, <<"synthetic-client-account">>,
           <<"synthetic-account">>, <<"synthetic-signature">>,
           <<"Bearer ">>, <<"authorization">>]),
    ExpectedTraces = [<<N:128>> || N <- [17, 18, 33, 34]],
    Valid = [S || S <- Spans, lists:member(maps:get(trace_id, S), ExpectedTraces)],
    12 = length(Valid),
    Rejected = Spans -- Valid,
    8 = length(Rejected),
    5 = length([S || S <- Rejected, maps:get(kind, S) =:= 'SPAN_KIND_SERVER']),
    3 = length([S || S <- Rejected, maps:get(kind, S) =:= 'SPAN_KIND_CLIENT']),
    lists:foreach(fun(S) -> [] = content_keys(S) end, Rejected),
    Groups = [group(Trace, Valid, Capture) || Trace <- ExpectedTraces],
    [{<<"/v1/chat/completions">>, false}, {<<"/v1/chat/completions">>, true},
     {<<"/v1/responses">>, false}, {<<"/v1/responses">>, true}] = lists:sort(Groups),
    [<<"/v1/traces">>] = lists:usort([maps:get(wire_path, S) || S <- Spans]),
    ok.

group(Trace, Spans, Capture) ->
    Group = [S || S <- Spans, maps:get(trace_id, S) =:= Trace],
    3 = length(Group),
    [Server] = [S || S <- Group, maps:get(kind, S) =:= 'SPAN_KIND_SERVER'],
    [Logical] = [S || S <- Group, attr(S, <<"gen_ai.operation.name">>) =:= <<"chat">>],
    [Attempt] = [S || S <- Group, maps:is_key(<<"pig.proxy.target.id">>, maps:get(attributes, S))],
    <<"1111111111111111">> = binary:encode_hex(maps:get(parent_span_id, Server), lowercase),
    ServerId = maps:get(span_id, Server),
    ServerId = maps:get(parent_span_id, Logical),
    LogicalId = maps:get(span_id, Logical),
    LogicalId = maps:get(parent_span_id, Attempt),
    'SPAN_KIND_CLIENT' = maps:get(kind, Logical),
    'SPAN_KIND_CLIENT' = maps:get(kind, Attempt),
    Route = attr(Server, <<"http.route">>),
    TraceHex = binary:encode_hex(Trace, lowercase),
    {ExpectedRoute, Stream, Input} = case TraceHex of
        <<"00000000000000000000000000000011">> -> {<<"/v1/responses">>, false, <<"codex-buffered-secret">>};
        <<"00000000000000000000000000000012">> -> {<<"/v1/responses">>, true, <<"codex-stream-secret">>};
        <<"00000000000000000000000000000021">> -> {<<"/v1/chat/completions">>, false, <<"zai-buffered-secret">>};
        <<"00000000000000000000000000000022">> -> {<<"/v1/chat/completions">>, true, <<"zai-stream-secret">>}
    end,
    ExpectedRoute = Route,
    {Api, Provider, Model, Target, Response, Output} = case Route of
        <<"/v1/responses">> ->
            {<<"responses">>, <<"openai">>, <<"fake-codex">>, <<"chatgpt">>,
             <<"responses-fixture">>, <<"responses-output-marker">>};
        <<"/v1/chat/completions">> ->
            {<<"chat_completions">>, <<"zai">>, <<"fake-zai">>, <<"zai">>,
             <<"chat-fixture">>, <<"chat-output-marker">>}
    end,
    Api = attr(Logical, <<"openai.api.type">>),
    Provider = attr(Logical, <<"gen_ai.provider.name">>),
    Model = attr(Logical, <<"gen_ai.request.model">>),
    Model = attr(Logical, <<"gen_ai.response.model">>),
    Response = attr(Logical, <<"gen_ai.response.id">>),
    [<<"stop">>] = attr(Logical, <<"gen_ai.response.finish_reasons">>),
    11 = attr(Logical, <<"gen_ai.usage.input_tokens">>),
    7 = attr(Logical, <<"gen_ai.usage.output_tokens">>),
    3 = attr(Logical, <<"gen_ai.usage.cache_read.input_tokens">>),
    Target = attr(Attempt, <<"pig.proxy.target.id">>),
    1 = attr(Attempt, <<"pig.proxy.attempt">>),
    lists:foreach(fun(S) ->
        true = maps:get(start, S) > 0,
        true = maps:get('end', S) >= maps:get(start, S),
        'STATUS_CODE_UNSET' = maps:get(code, maps:get(status, S), 'STATUS_CODE_UNSET'),
        <<"succeeded">> = attr(S, <<"pig.outcome">>),
        [] = maps:get(events, S), [] = maps:get(links, S)
    end, Group),
    200 = attr(Server, <<"http.response.status_code">>),
    200 = attr(Attempt, <<"http.response.status_code">>),
    lists:foreach(fun(S) -> [] = content_keys(S) end, [Server, Attempt]),
    case Capture of
        false ->
            lists:foreach(fun(S) -> [] = content_keys(S) end, Group),
            nomatch = binary:match(term_to_binary(Group), Input),
            nomatch = binary:match(term_to_binary(Group), Output);
        true ->
            Attrs = maps:get(attributes, Logical),
            <<"captured">> = maps:get(<<"pig.content.input.status">>, Attrs),
            <<"captured">> = maps:get(<<"pig.content.output.status">>, Attrs),
            #{<<"gen_ai.input.messages">> := InputJson,
              <<"gen_ai.output.messages">> := OutputJson} = Attrs,
            InputMessages = json:decode(InputJson),
            OutputMessages = json:decode(OutputJson),
            true = binary:match(term_to_binary(InputMessages), Input) =/= nomatch,
            true = binary:match(term_to_binary(OutputMessages), Output) =/= nomatch
    end,
    {Route, Stream}.

attr(Span, Key) -> maps:get(Key, maps:get(attributes, Span), undefined).
content_keys(Span) ->
    [K || K <- maps:keys(maps:get(attributes, Span)), content_key(K)].
content_key(<<"gen_ai.input.", _/binary>>) -> true;
content_key(<<"gen_ai.output.", _/binary>>) -> true;
content_key(<<"gen_ai.system_instructions">>) -> true;
content_key(<<"gen_ai.tool.definitions">>) -> true;
content_key(_) -> false.
