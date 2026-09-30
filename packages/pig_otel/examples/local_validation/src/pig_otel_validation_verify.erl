%% Pure normalized-span contract, shared by official ETS and OTLP snapshots.
-module(pig_otel_validation_verify).
-export([check/2, check_agents/2, check_proxy_sync/2, check_failure/2,
         safe_metadata/1, unique_ids/1, related/2]).

check(Spans, Facts) ->
    20 = length(Spans),
    true = unique_ids(Spans),
    true = safe_metadata(Spans),
    lists:foreach(fun valid_span/1, Spans),
    Pig = scope(<<"pig">>, Spans),
    Proxy = scope(<<"pig_proxy">>, Spans),
    8 = length(Pig),
    12 = length(Proxy),
    check_pig(Pig, Facts),
    check_proxy(Proxy, Facts, 4),
    ok.

check_agents(Spans, Facts) ->
    8 = length(Spans),
    8 = length(scope(<<"pig">>, Spans)),
    true = unique_ids(Spans),
    true = safe_metadata(Spans),
    lists:foreach(fun valid_span/1, Spans),
    check_pig(Spans, Facts).

check_proxy_sync(Spans, Facts) ->
    6 = length(Spans),
    6 = length(scope(<<"pig_proxy">>, Spans)),
    true = unique_ids(Spans),
    true = safe_metadata(Spans),
    lists:foreach(fun valid_span/1, Spans),
    check_proxy(Spans, Facts, 2).

check_failure(Spans, Facts) ->
    2 = length(Spans),
    true = unique_ids(Spans),
    true = safe_metadata(Spans),
    [Run] = operation(<<"invoke_agent">>, Spans),
    [Inference] = operation(<<"chat">>, Spans),
    true = related(Run, Inference),
    [{callback, <<"provider">>, Trace, Id}] = [F || F={callback, _, _, _} <- Facts],
    Trace = maps:get(trace_id, Inference),
    Id = maps:get(span_id, Inference),
    lists:foreach(fun(#{scope := Scope, version := Version, status := Status,
                       schema := Schema, start := Start, 'end' := End, attributes := A}) ->
        <<"pig">> = Scope,
        <<"0.6.0">> = Version,
        <<>> = Schema,
        error = Status,
        true = Start > 0 andalso End >= Start,
        <<"failed">> = maps:get(<<"pig.outcome">>, A),
        <<"provider_error">> = maps:get(<<"error.type">>, A),
        false = maps:is_key(<<"gen_ai.usage.input_tokens">>, A),
        false = maps:is_key(<<"gen_ai.usage.output_tokens">>, A)
    end, Spans).

unique_ids(Spans) ->
    Ids = [{maps:get(trace_id, S), maps:get(span_id, S)} || S <- Spans],
    length(Ids) =:= length(lists:usort(Ids)).

safe_metadata(Term) ->
    %% Sentinel content is present in actual business inputs/outputs and absent
    %% from every exported attribute, event, link, name and status.
    binary:match(term_to_binary(Term), <<"PRIVATE_">>) =:= nomatch.

related(Parent, Child) ->
    maps:get(trace_id, Parent) =:= maps:get(trace_id, Child) andalso
    maps:get(span_id, Parent) =:= maps:get(parent_span_id, Child).

valid_span(#{trace_id := Trace, span_id := Id, start := Start, 'end' := End,
             status := Status, attributes := Attrs, scope := Scope,
             version := Version, schema := Schema, events := Events, links := Links}) ->
    32 = byte_size(Trace),
    16 = byte_size(Id),
    true = Start > 0 andalso End >= Start,
    unset = Status,
    <<"succeeded">> = maps:get(<<"pig.outcome">>, Attrs),
    <<>> = Schema,
    [] = Events,
    [] = Links,
    case Scope of
        <<"pig">> -> <<"0.6.0">> = Version;
        <<"pig_proxy">> -> <<"0.2.0">> = Version
    end,
    Forbidden = [<<"gen_ai.input.messages">>, <<"gen_ai.output.messages">>,
                 <<"gen_ai.system_instructions">>, <<"gen_ai.tool.call.arguments">>,
                 <<"gen_ai.tool.call.result">>, <<"exception.message">>,
                 <<"exception.stacktrace">>, <<"url.full">>, <<"baggage">>],
    [] = [K || K <- Forbidden, maps:is_key(K, Attrs)].

scope(Name, Spans) -> [S || S=#{scope := N} <- Spans, N =:= Name].
operation(Name, Spans) -> [S || S=#{attributes := A} <- Spans,
                              maps:get(<<"gen_ai.operation.name">>, A, undefined) =:= Name].
children(Parent, Spans) -> [S || S <- Spans, related(Parent, S)].

check_pig(Spans, Facts) ->
    Runs = operation(<<"invoke_agent">>, Spans),
    2 = length(Runs),
    4 = length(operation(<<"chat">>, Spans)),
    2 = length(operation(<<"execute_tool">>, Spans)),
    RunIds = [maps:get(<<"pig.run.id">>, maps:get(attributes, R)) || R <- Runs],
    2 = length(lists:usort(RunIds)),
    lists:foreach(fun(Run) ->
        TraceId = maps:get(trace_id, Run),
        [ParentId] = [P || {caller, T, P} <- Facts, T =:= TraceId],
        ParentId = maps:get(parent_span_id, Run),
        internal = maps:get(kind, Run),
        Children = children(Run, Spans),
        3 = length(Children),
        [Tool] = operation(<<"execute_tool">>, Children),
        internal = maps:get(kind, Tool),
        2 = length(operation(<<"chat">>, Children)),
        lists:foreach(fun(S) ->
            client = maps:get(kind, S),
            check_usage(S),
            <<"fixture_response">> = attr(<<"gen_ai.response.id">>, S),
            <<"fixture_model">> = attr(<<"gen_ai.response.model">>, S),
            %% A custom provider's identity/model are unknown, not invented.
            false = maps:is_key(<<"gen_ai.provider.name">>, maps:get(attributes, S)),
            false = maps:is_key(<<"gen_ai.request.model">>, maps:get(attributes, S))
        end, operation(<<"chat">>, Children))
    end, Runs),
    Callbacks = [F || F={callback, _, _, _} <- Facts],
    6 = length(Callbacks),
    lists:foreach(fun({callback, Label, Trace, Id}) ->
        [Span] = [S || S=#{trace_id := T, span_id := I} <- Spans, T =:= Trace, I =:= Id],
        Expected = case Label of <<"tool">> -> <<"execute_tool">>; <<"provider">> -> <<"chat">> end,
        Expected = attr(<<"gen_ai.operation.name">>, Span)
    end, Callbacks).

check_proxy(Spans, Facts, Expected) ->
    Ingress = [F || F={ingress, _, _, _, _} <- Facts],
    Expected = length(Ingress),
    lists:foreach(fun({ingress, Trace, Parent, Route, Streaming}) ->
        InTrace = [S || S=#{trace_id := T} <- Spans, T =:= Trace],
        3 = length(InTrace),
        case Streaming of
            false -> ok;
            true ->
                [Observed] = [Ts || {stream_observed, T, Ts} <- Facts, T =:= Trace],
                lists:foreach(fun(#{start := Start, 'end' := End}) ->
                    true = Start =< Observed andalso End >= Observed
                end, InTrace)
        end,
        [Server] = [S || S=#{kind := server} <- InTrace],
        Parent = maps:get(parent_span_id, Server),
        Route = attr(<<"http.route">>, Server),
        200 = attr(<<"http.response.status_code">>, Server),
        [Logical] = children(Server, InTrace),
        client = maps:get(kind, Logical),
        <<"chat">> = attr(<<"gen_ai.operation.name">>, Logical),
        Api = case Route of <<"/v1/responses">> -> <<"responses">>; _ -> <<"chat_completions">> end,
        Api = attr(<<"openai.api.type">>, Logical),
        check_usage(Logical),
        [Attempt] = children(Logical, InTrace),
        client = maps:get(kind, Attempt),
        200 = attr(<<"http.response.status_code">>, Attempt),
        <<"fixture">> = attr(<<"pig.proxy.target.id">>, Attempt),
        Id = maps:get(span_id, Attempt),
        Traceparent = <<"00-", Trace/binary, "-", Id/binary, "-01">>,
        1 = length([ok || {outbound, P, TP} <- Facts, P =:= Route, TP =:= Traceparent])
    end, Ingress).

check_usage(S) ->
    5 = attr(<<"gen_ai.usage.input_tokens">>, S),
    3 = attr(<<"gen_ai.usage.output_tokens">>, S),
    2 = attr(<<"gen_ai.usage.cache_read.input_tokens">>, S).
attr(Key, Span) -> maps:get(Key, maps:get(attributes, Span)).
