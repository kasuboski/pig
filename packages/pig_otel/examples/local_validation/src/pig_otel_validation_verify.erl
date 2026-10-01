%% Pure normalized-span contract, shared by official ETS and OTLP snapshots.
-module(pig_otel_validation_verify).
-export([check/2, check_agents/2, check_proxy_sync/2, check_proxy_content/2,
         check_proxy_content_overflow/2, check_proxy_content_malformed/2,
         check_proxy_content_retry/2, check_proxy_content_interrupt/2,
         check_failure/2, safe_metadata/1, content_private_values/1,
         unique_ids/1, related/2]).

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

check_proxy_content(Spans, Facts) ->
    12 = length(Spans),
    true = unique_ids(Spans),
    Ingress = [F || F={ingress, _, _, _, _} <- Facts, element(2, F) >= <<"0000000000000000000000000000000b">>],
    4 = length(Ingress),
    lists:foreach(fun({ingress, Trace, Parent, Route, Streaming}) ->
        Group = [S || S=#{trace_id := T} <- Spans, T =:= Trace],
        3 = length(Group),
        [Server] = [S || S=#{kind := server} <- Group],
        [Logical] = [S || S=#{kind := client, attributes := A} <- Group,
                           maps:get(<<"gen_ai.operation.name">>, A, undefined) =:= <<"chat">>],
        [Attempt] = [S || S=#{kind := client, attributes := A} <- Group,
                           maps:is_key(<<"pig.proxy.target.id">>, A)],
        true = related(Server, Logical),
        true = related(Logical, Attempt),
        Parent = maps:get(parent_span_id, Server),
        200 = attr(<<"http.response.status_code">>, Server),
        200 = attr(<<"http.response.status_code">>, Attempt),
        unset = maps:get(status, Logical),
        <<"succeeded">> = attr(<<"pig.outcome">>, Logical),
        Route = attr(<<"http.route">>, Server),
        ExpectedApi = case Route of <<"/v1/responses">> -> responses; _ -> chat end,
        ApiName = case ExpectedApi of responses -> "responses"; chat -> "chat" end,
        ApiBin = case ExpectedApi of responses -> <<"responses">>; chat -> <<"chat_completions">> end,
        ApiBin = attr(<<"openai.api.type">>, Logical),
        AttemptId = maps:get(span_id, Attempt),
        ExpectedTraceparent = <<"00-", Trace/binary, "-", AttemptId/binary, "-01">>,
        1 = length([ok || {outbound, P, TP} <- Facts, P =:= Route, TP =:= ExpectedTraceparent]),
        ok = verify_content_direction(Logical, input, ApiName),
        ok = verify_content_direction(Logical, output, ApiName),
        11 = attr(<<"gen_ai.usage.input_tokens">>, Logical),
        7 = attr(<<"gen_ai.usage.output_tokens">>, Logical),
        ResponseId = case ExpectedApi of chat -> <<"response-chat-content">>;
            responses -> <<"response-responses-content">> end,
        ResponseId = attr(<<"gen_ai.response.id">>, Logical),
        <<"fixture_model">> = attr(<<"gen_ai.response.model">>, Logical),
        Finish = maps:get(<<"gen_ai.response.finish_reasons">>,
                          maps:get(attributes, Logical), []),
        true = is_list(Finish),
        true = lists:all(fun is_binary/1, Finish),
        [<<"stop">>] = Finish,
        false = maps:is_key(<<"gen_ai.usage.cache_read.input_tokens">>, maps:get(attributes, Logical)),
        [] = [K || K <- [<<"url.full">>, <<"baggage">>, <<"http.request.header.authorization">>,
                          <<"exception.message">>, <<"exception.stacktrace">>],
                   maps:is_key(K, maps:get(attributes, Server))],
        ok = content_private_values(Group),
        AllowedContentKeys = [<<"gen_ai.input.messages">>, <<"gen_ai.output.messages">>,
            <<"gen_ai.system_instructions">>, <<"gen_ai.tool.definitions">>],
        lists:foreach(fun(#{attributes := A}) ->
            [] = [K || K <- maps:keys(A), is_content_key(K),
                        not lists:member(K, AllowedContentKeys)]
        end, Group),
        case Streaming of
            true ->
                [Observed] = [Ts || {stream_observed, T, Ts} <- Facts, T =:= Trace],
                true = maps:get(start, Logical) =< Observed andalso maps:get('end', Logical) >= Observed;
            false -> ok
        end
    end, Ingress),
    ok.

verify_content_direction(Span, Direction, Api) ->
    Prefix = case Direction of input -> "input"; output -> "output" end,
    StatusKey = list_to_binary("pig.content." ++ Prefix ++ ".status"),
    ReasonKey = list_to_binary("pig.content." ++ Prefix ++ ".reason"),
    Attrs = maps:get(attributes, Span),
    Status = maps:get(StatusKey, Attrs),
    true = lists:member(Status, [<<"captured">>, <<"filtered">>]),
    Reason = maps:get(ReasonKey, Attrs),
    true = lists:member(Reason, [<<"complete">>, <<"redacted_or_excluded">>]),
    true = ((Status =:= <<"captured">> andalso Reason =:= <<"complete">>) orelse
            (Status =:= <<"filtered">> andalso Reason =:= <<"redacted_or_excluded">>)),
    ExpectedFile = filename:join(["test_data", "content", Api ++ "-" ++ Prefix ++ ".json"]),
    {ok, ExpectedBytes} = file:read_file(ExpectedFile),
    Expected = json:decode(ExpectedBytes),
    maps:foreach(fun(Key, Value) ->
        ActualString = maps:get(Key, Attrs),
        true = is_binary(ActualString),
        Value = json:decode(ActualString)
    end, Expected),
    DirectionKeys = case Direction of
        input -> [<<"gen_ai.input.messages">>, <<"gen_ai.system_instructions">>, <<"gen_ai.tool.definitions">>];
        output -> [<<"gen_ai.output.messages">>]
    end,
    ContentKeys = [K || K <- maps:keys(Attrs), lists:member(K, DirectionKeys)],
    true = length(ContentKeys) =:= map_size(Expected),
    ok.

is_content_key(<<"gen_ai.input.", _/binary>>) -> true;
is_content_key(<<"gen_ai.output.", _/binary>>) -> true;
is_content_key(<<"gen_ai.system_instructions">>) -> true;
is_content_key(<<"gen_ai.tool.definitions">>) -> true;
is_content_key(_) -> false.

check_proxy_content_malformed(Spans, Facts) ->
    6 = length(Spans),
    true = unique_ids(Spans),
    lists:foreach(fun({ingress, Trace, Parent, Route, true}) ->
        Group = [S || S=#{trace_id := T} <- Spans, T =:= Trace],
        3 = length(Group),
        [Server] = [S || S=#{kind := server} <- Group],
        [Logical] = operation(<<"chat">>, Group),
        [Attempt] = [S || S=#{attributes := A} <- Group,
            maps:is_key(<<"pig.proxy.target.id">>, A)],
        Parent = maps:get(parent_span_id, Server),
        true = related(Server, Logical),
        true = related(Logical, Attempt),
        200 = attr(<<"http.response.status_code">>, Server),
        200 = attr(<<"http.response.status_code">>, Attempt),
        Route = attr(<<"http.route">>, Server),
        <<"succeeded">> = attr(<<"pig.outcome">>, Logical),
        Api = case Route of <<"/v1/responses">> -> "responses"; _ -> "chat" end,
        ok = verify_content_direction(Logical, input, Api),
        Attrs = maps:get(attributes, Logical),
        <<"omitted">> = maps:get(<<"pig.content.output.status">>, Attrs),
        <<"invalid_json">> = maps:get(<<"pig.content.output.reason">>, Attrs),
        false = maps:is_key(<<"gen_ai.output.messages">>, Attrs),
        true = safe_content_metadata(Group),
        [] = [K || S <- [Server, Attempt], K <- maps:keys(maps:get(attributes, S)), is_content_key(K)],
        [ _ ] = [ok || {stream_observed, T, _} <- Facts, T =:= Trace]
    end, [F || F={ingress, _, _, _, _} <- Facts]),
    ok.

check_proxy_content_interrupt(Spans, Facts) ->
    6 = length(Spans),
    true = unique_ids(Spans),
    lists:foreach(fun({ingress, Trace, Parent, Route, true}) ->
        Group = [S || S=#{trace_id := T} <- Spans, T =:= Trace],
        3 = length(Group),
        [Server] = [S || S=#{kind := server} <- Group],
        [Logical] = operation(<<"chat">>, Group),
        [Attempt] = [S || S=#{attributes := A} <- Group,
            maps:is_key(<<"pig.proxy.target.id">>, A)],
        Parent = maps:get(parent_span_id, Server),
        true = related(Server, Logical),
        true = related(Logical, Attempt),
        Route = attr(<<"http.route">>, Server),
        Api = case Route of <<"/v1/responses">> -> "responses"; _ -> "chat" end,
        ok = verify_content_direction(Logical, input, Api),
        lists:foreach(fun verify_interrupted_terminal/1, Group),
        200 = attr(<<"http.response.status_code">>, Server),
        200 = attr(<<"http.response.status_code">>, Attempt),
        Attrs = maps:get(attributes, Logical),
        <<"omitted">> = maps:get(<<"pig.content.output.status">>, Attrs),
        <<"incomplete">> = maps:get(<<"pig.content.output.reason">>, Attrs),
        false = maps:is_key(<<"gen_ai.output.messages">>, Attrs),
        true = safe_content_metadata(Group),
        [] = [K || S <- [Server, Attempt], K <- maps:keys(maps:get(attributes, S)), is_content_key(K)],
        [ _ ] = [ok || {stream_observed, T, _} <- Facts, T =:= Trace]
    end, [F || F={ingress, _, _, _, _} <- Facts]),
    ok.

verify_interrupted_terminal(Span) ->
    error = maps:get(status, Span),
    Outcome = attr(<<"pig.outcome">>, Span),
    Error = attr(<<"error.type">>, Span),
    true = lists:member({Outcome, Error}, [
        {<<"cancelled">>, <<"client_disconnected">>},
        {<<"cancelled">>, <<"agent_stopped">>},
        {<<"failed">>, <<"transport_error">>},
        {<<"failed">>, <<"downstream_error">>},
        {<<"failed">>, <<"http_error">>}
    ]),
    ok.

check_proxy_content_retry(Spans, Facts) ->
    16 = length(Spans),
    true = unique_ids(Spans),
    true = safe_content_metadata(Spans),
    Ingress = [F || F={ingress, _, _, _, _} <- Facts],
    4 = length(Ingress),
    Success = lists:flatmap(fun({ingress, Trace, _, Route, _}) ->
        Group = [S || S=#{trace_id := T} <- Spans, T =:= Trace],
        4 = length(Group),
        [Server] = [S || S=#{kind := server} <- Group],
        [Logical] = operation(<<"chat">>, Group),
        Attempts = [S || S=#{attributes := A} <- Group,
            maps:is_key(<<"pig.proxy.target.id">>, A)],
        2 = length(Attempts),
        [Failed] = [S || S <- Attempts, attr(<<"http.response.status_code">>, S) =:= 503],
        [Final] = [S || S <- Attempts, attr(<<"http.response.status_code">>, S) =:= 200],
        1 = attr(<<"pig.proxy.attempt">>, Failed),
        2 = attr(<<"pig.proxy.attempt">>, Final),
        error = maps:get(status, Failed),
        <<"failed">> = attr(<<"pig.outcome">>, Failed),
        <<"http_error">> = attr(<<"error.type">>, Failed),
        true = related(Logical, Failed),
        true = related(Logical, Final),
        true = related(Server, Logical),
        [Body, Body] = [B || {forwarded_body, P, B, TP} <- Facts, P =:= Route,
                            binary:part(TP, 3, 32) =:= Trace],
        ExpectedParents = lists:sort([<<"00-", Trace/binary, "-",
            (maps:get(span_id, S))/binary, "-01">> || S <- Attempts]),
        ExpectedParents = lists:sort([TP || {outbound, P, TP} <- Facts, P =:= Route,
                                                   binary:part(TP, 3, 32) =:= Trace]),
        [] = [K || K <- maps:keys(maps:get(attributes, Failed)), is_content_key(K)],
        [Server, Logical, Final]
    end, Ingress),
    FilteredFacts = [F || F={outbound, Route, TP} <- Facts,
        lists:any(fun(S) ->
            maps:get(span_id, S) =:= binary:part(TP, 36, 16) andalso
            attr(<<"http.response.status_code">>, S) =:= 200 andalso
            attr(<<"http.route">>, hd([X || X <- Success,
                maps:get(trace_id, X) =:= maps:get(trace_id, S), maps:get(kind, X) =:= server])) =:= Route
        end, [S || S <- Success, maps:is_key(<<"pig.proxy.target.id">>, maps:get(attributes, S))])]
        ++ [F || F <- Facts, element(1, F) =/= outbound],
    nomatch = binary:match(term_to_binary(Spans), <<"PRIVATE_RETRY_ENVELOPE">>),
    check_proxy_content(Success, FilteredFacts).

content_private_values(Group) ->
    Encoded = term_to_binary(Group),
    lists:foreach(fun(#{scope := Scope, version := Version, schema := Schema,
                        trace_id := Trace, span_id := Id, start := Start, 'end' := End,
                        status := Status, events := Events, links := Links, attributes := Attrs}) ->
        <<"pig_proxy">> = Scope,
        <<"0.2.0">> = Version,
        <<>> = Schema,
        32 = byte_size(Trace),
        16 = byte_size(Id),
        true = Start > 0 andalso End >= Start,
        unset = Status,
        <<"succeeded">> = maps:get(<<"pig.outcome">>, Attrs),
        [] = Events,
        [] = Links,
        ForbiddenKeys = [<<"url.full">>, <<"baggage">>, <<"http.request.header.authorization">>,
                         <<"authorization">>, <<"exception.message">>, <<"exception.stacktrace">>,
                         <<"error.message">>, <<"gen_ai.reasoning">>,
                         <<"gen_ai.output.messages.reasoning">>,
                         <<"gen_ai.tool.call.arguments">>, <<"gen_ai.tool.call.result">>,
                         <<"gen_ai.tool.definitions.schema">>],
        [] = [K || K <- ForbiddenKeys, maps:is_key(K, Attrs)]
    end, Group),
    Forbidden = [<<"NEVER_EXPORT_">>, <<"PRIVATE_">>, <<"Bearer ">>, <<"PRIVATE_API_KEY">>,
                 <<"PRIVATE_INGRESS_KEY">>, <<"PRIVATE_BAGGAGE">>, <<"never-export.invalid">>],
    [] = [V || V <- Forbidden, binary:match(Encoded, V) =/= nomatch],
    lists:foreach(fun(#{scope := Scope, events := Events, links := Links, attributes := Attrs}) ->
        [] = Events,
        [] = Links,
        case Scope of
            <<"pig_proxy">> -> ok;
            _ -> error(unexpected_content_scope)
        end,
        [] = [K || K <- [<<"gen_ai.input.messages">>, <<"gen_ai.output.messages">>,
                          <<"gen_ai.system_instructions">>, <<"gen_ai.tool.definitions">>],
                   maps:is_key(K, Attrs)]
    end, [S || S=#{kind := server} <- Group] ++ [S || S=#{attributes := A} <- Group,
                    maps:is_key(<<"pig.proxy.target.id">>, A)]),
    ok.

check_proxy_content_overflow(Spans, Facts) ->
    12 = length(Spans),
    true = unique_ids(Spans),
    Ingress = [F || F={ingress, _, _, _, _} <- Facts,
                    element(2, F) >= <<"0000000000000000000000000000000b">>],
    4 = length(Ingress),
    lists:foreach(fun({ingress, Trace, Parent, Route, Streaming}) ->
        Group = [S || S=#{trace_id := T} <- Spans, T =:= Trace],
        3 = length(Group),
        [Server] = [S || S=#{kind := server} <- Group],
        [Logical] = [S || S=#{kind := client, attributes := A} <- Group,
                           maps:get(<<"gen_ai.operation.name">>, A, undefined) =:= <<"chat">>],
        [Attempt] = [S || S=#{kind := client, attributes := A} <- Group,
                           maps:is_key(<<"pig.proxy.target.id">>, A)],
        Parent = maps:get(parent_span_id, Server),
        true = related(Server, Logical),
        true = related(Logical, Attempt),
        Route = attr(<<"http.route">>, Server),
        200 = attr(<<"http.response.status_code">>, Server),
        200 = attr(<<"http.response.status_code">>, Attempt),
        11 = attr(<<"gen_ai.usage.input_tokens">>, Logical),
        7 = attr(<<"gen_ai.usage.output_tokens">>, Logical),
        Attrs = maps:get(attributes, Logical),
        lists:foreach(fun(Direction) ->
            Prefix = atom_to_binary(Direction, utf8),
            <<"omitted">> = maps:get(<<"pig.content.", Prefix/binary, ".status">>, Attrs),
            <<"source_limit">> = maps:get(<<"pig.content.", Prefix/binary, ".reason">>, Attrs)
        end, [input, output]),
        [] = [K || K <- [<<"gen_ai.input.messages">>, <<"gen_ai.output.messages">>,
                          <<"gen_ai.system_instructions">>, <<"gen_ai.tool.definitions">>],
                   maps:is_key(K, Attrs)],
        [] = [K || S <- Group, K <- [<<"gen_ai.input.messages">>, <<"gen_ai.output.messages">>,
                                     <<"gen_ai.system_instructions">>, <<"gen_ai.tool.definitions">>],
                   maps:is_key(K, maps:get(attributes, S))],
        true = safe_content_metadata(Group),
        case Streaming of
            true -> [ _ ] = [ok || {stream_observed, T, _} <- Facts, T =:= Trace];
            false -> ok
        end
    end, Ingress),
    ok.

safe_content_metadata(Group) ->
    Encoded = term_to_binary(Group),
    [] = [V || V <- [<<"PRIVATE_">>, <<"NEVER_EXPORT_">>], binary:match(Encoded, V) =/= nomatch],
    true.

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
