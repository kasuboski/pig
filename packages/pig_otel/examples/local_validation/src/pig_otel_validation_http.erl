%% Local upstream + real proxy HTTP client. No paid APIs or external endpoints.
-module(pig_otel_validation_http).
-export([check_proxy/1, check_proxy_sync/1, check_proxy_content/1,
         check_proxy_content_overflow/1, check_proxy_content_malformed/1,
         check_proxy_content_retry/1, check_proxy_content_interrupt/1]).
-include_lib("opentelemetry/include/otel_span.hrl").
-include_lib("opentelemetry_api/include/opentelemetry.hrl").

check_proxy(Start) ->
    check_proxy_matrix(Start, [{"/v1/chat/completions", false, 1},
                               {"/v1/responses", false, 2},
                               {"/v1/chat/completions", true, 3},
                               {"/v1/responses", true, 4}]).

check_proxy_sync(Start) ->
    check_proxy_matrix(Start, [{"/v1/chat/completions", false, 1},
                               {"/v1/responses", false, 2}]).

check_proxy_content(Start) ->
    check_proxy_content_matrix(Start,
        [{"/v1/chat/completions", false, 11}, {"/v1/responses", false, 12},
         {"/v1/chat/completions", true, 13}, {"/v1/responses", true, 14}]).

check_proxy_content_overflow(Start) ->
    check_proxy_content_matrix(Start,
        [{"/v1/chat/completions", false, 11}, {"/v1/responses", false, 12},
         {"/v1/chat/completions", true, 13}, {"/v1/responses", true, 14}]).

check_proxy_content_malformed(Start) ->
    check_proxy_matrix(Start, [{"/v1/chat/completions", true, 11},
                               {"/v1/responses", true, 12}], content_malformed).

check_proxy_content_interrupt(Start) ->
    check_proxy_matrix(Start, [{"/v1/chat/completions", true, 11}], content_interrupt),
    check_proxy_matrix(Start, [{"/v1/responses", true, 12}], content_interrupt).

check_proxy_content_retry(Start) ->
    check_proxy_matrix(Start, [{"/v1/chat/completions", false, 11},
                               {"/v1/responses", false, 12},
                               {"/v1/chat/completions", true, 13},
                               {"/v1/responses", true, 14}], content_retry).

check_proxy_matrix(Start, Cases) ->
    check_proxy_matrix(Start, Cases, ordinary).

check_proxy_content_matrix(Start, Cases) ->
    check_proxy_matrix(Start, Cases, content).

check_proxy_matrix(Start, Cases, FixtureMode) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {packet, http_bin},
        {active, false}, {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, UpstreamPort}} = inet:sockname(Listener),
    {ok, Reservation} = gen_tcp:listen(0, [{ip, {127,0,0,1}}]),
    {ok, {_, ProxyPort}} = inet:sockname(Reservation),
    gen_tcp:close(Reservation),
    Parent = self(),
    ets:insert(pig_otel_validation_facts, {fixture_mode, FixtureMode}),
    {Upstream, UpMon} = spawn_monitor(fun() -> upstream(Listener, length(Cases) *
        case FixtureMode of content_retry -> 2; _ -> 1 end) end),
    Ref = make_ref(),
    {Proxy, ProxyMon} = spawn_monitor(fun() ->
        Start(ProxyPort, iolist_to_binary(["http://127.0.0.1:", integer_to_list(UpstreamPort), "/v1"])),
        Parent ! {Ref, ready},
        receive
            stop ->
                pig_otel_validation_host:stop_proxy_owners(),
                exit(shutdown)
        end
    end),
    try
        receive
            {Ref, ready} -> ok;
            {'DOWN', ProxyMon, process, Proxy, Why} -> error({proxy_start_failed, Why})
        after 10000 -> error(proxy_start_timeout) end,
        lists:foreach(fun({Path, Streaming, Index}) ->
            request(ProxyPort, Path, Streaming, Index, FixtureMode)
        end, Cases),
        receive
            {'DOWN', UpMon, process, Upstream, normal} -> ok;
            {'DOWN', UpMon, process, Upstream, Why2} -> error({upstream_failed, Why2})
        after 10000 -> error(upstream_terminal_timeout) end
    after
        Proxy ! stop,
        receive {'DOWN', ProxyMon, process, Proxy, _} -> ok
        after 5000 -> exit(Proxy, kill), receive {'DOWN', ProxyMon, process, Proxy, _} -> ok end end,
        gen_tcp:close(Listener),
        exit(Upstream, kill),
        erlang:demonitor(UpMon, [flush]),
        ets:delete(pig_otel_validation_facts, fixture_mode)
    end,
    nil.

request(Port, Path, Streaming, Index, FixtureMode) ->
    Body = case FixtureMode of
        ordinary -> iolist_to_binary(["{\"model\":\"fixture_model\",\"stream\":", atom_to_list(Streaming),
                    ",\"messages\":[{\"role\":\"user\",\"content\":\"PRIVATE_PROMPT\"}]} "]);
        content -> content_request(Path, Streaming);
        content_malformed -> content_request(Path, Streaming);
        content_retry -> content_request(Path, Streaming);
        content_interrupt -> content_request(Path, Streaming)
    end,
    Trace = iolist_to_binary(io_lib:format("~32.16.0b", [Index])),
    Parent = <<"1111111111111111">>,
    Traceparent = <<"00-", Trace/binary, "-", Parent/binary, "-01">>,
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    Headers = [{"traceparent", binary_to_list(Traceparent)},
               {"tracestate", "fixture=valid"},
               {"baggage", "secret=PRIVATE_BAGGAGE"},
               {"BAGGAGE", "broken"}, {"authorization", "Bearer PRIVATE_INGRESS_KEY"}],
    Response = case Streaming of
        false ->
            {ok, {{_, 200, _}, _, Reply}} = httpc:request(post,
                {Url, Headers, "application/json", Body}, [{timeout, 10000}], [{body_format, binary}]),
            Reply;
        true when FixtureMode =:= content_interrupt ->
            raw_interrupt(Port, Path, Headers, Body, Trace);
        true ->
            {ok, RequestId} = httpc:request(post,
                {Url, Headers, "application/json", Body}, [{timeout, 10000}],
                [{body_format, binary}, {sync, false}, {stream, self}]),
            try client_stream(RequestId, list_to_binary(Path), Trace, [], false,
                              FixtureMode)
            after httpc:cancel_request(RequestId) end
    end,
    true = byte_size(Response) > 0,
    {_, FinalBody} = response(list_to_binary(Path), Streaming, FixtureMode),
    FirstBody = case Streaming of
        false -> <<>>;
        true when FixtureMode =/= ordinary -> fixture("content/" ++ api(list_to_binary(Path)) ++ "-stream-first.sse");
        true -> first_chunk(list_to_binary(Path), true)
    end,
    case FixtureMode of
        content_interrupt -> FirstBody = Response;
        _ -> Response = <<FirstBody/binary, FinalBody/binary>>
    end,
    ets:insert(pig_otel_validation_facts, {ingress, Trace, Parent,
                                        list_to_binary(Path), Streaming}),
    ok.

client_stream(Id, Path, Trace, Acc, Seen, Mode) ->
    receive
        {http, {Id, stream_start, _Headers}} -> client_stream(Id, Path, Trace, Acc, Seen, Mode);
        {http, {Id, stream, Chunk}} when byte_size(Chunk) > 0 ->
            case Seen of
                true -> ok;
                false ->
                    %% Actual downstream first body receipt releases late upstream
                    %% usage. This is an ACK barrier, not a scheduling sleep.
                    Timestamp = opentelemetry:timestamp_to_nano(opentelemetry:timestamp()),
                    ets:insert(pig_otel_validation_facts, {stream_observed, Trace, Timestamp}),
                    [{mode, TraceMode}] = ets:lookup(pig_otel_validation_facts, mode),
                    case TraceMode of
                        recording ->
                            TraceId = binary_to_integer(Trace, 16),
                            Ended = [S || S=#span{trace_id=T} <- ets:tab2list(pig_otel_validation_spans), T =:= TraceId],
                            case Mode of
                                content_retry ->
                                    [#span{attributes=Attrs, status=#status{code=error}}] = Ended,
                                    AttemptAttrs = otel_attributes:map(Attrs),
                                    503 = maps:get(<<"http.response.status_code">>, AttemptAttrs),
                                    1 = maps:get(<<"pig.proxy.attempt">>, AttemptAttrs),
                                    <<"failed">> = maps:get(<<"pig.outcome">>, AttemptAttrs),
                                    false = maps:is_key(<<"openai.api.type">>, AttemptAttrs);
                                _ -> [] = Ended
                            end;
                        _ -> ok
                    end,
                    [{stream_release, Path, Upstream}] = ets:lookup(pig_otel_validation_facts, stream_release),
                    Upstream ! {release, Path}
            end,
            client_stream(Id, Path, Trace, [Chunk | Acc], true, Mode);
        {http, {Id, stream_end, _Headers}} ->
            true = Seen,
            iolist_to_binary(lists:reverse(Acc));
        {http, {Id, {error, Reason}}} -> error({stream_client_error, Reason});
        {http, {Id, Other}} -> error({unexpected_stream_reply, Other})
    after 10000 -> error(downstream_chunk_timeout) end.

raw_interrupt(Port, Path, Headers, Body, Trace) ->
    {ok, Socket} = gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 10000),
    First = fixture("content/" ++ api(list_to_binary(Path)) ++ "-stream-first.sse"),
    try
        HeaderLines = [[K, ": ", V, "\r\n"] || {K, V} <- Headers],
        ok = gen_tcp:send(Socket, ["POST ", Path, " HTTP/1.1\r\nHost: 127.0.0.1:",
            integer_to_list(Port), "\r\n", HeaderLines,
            "Content-Length: ", integer_to_list(byte_size(Body)),
            "\r\nConnection: close\r\n\r\n", Body]),
        receive_interrupt_body(Socket, First, <<>>, Trace)
    after
        gen_tcp:close(Socket),
        signal_interrupt(list_to_binary(Path))
    end.

signal_interrupt(Path) ->
    [{stream_release, Path, Upstream}] = ets:lookup(pig_otel_validation_facts, stream_release),
    Upstream ! {cancel, Path}.

receive_interrupt_body(Socket, First, Acc, Trace) ->
    {ok, Chunk} = gen_tcp:recv(Socket, 0, 10000),
    Received = <<Acc/binary, Chunk/binary>>,
    case binary:match(Received, First) of
        nomatch -> receive_interrupt_body(Socket, First, Received, Trace);
        _ ->
            ets:insert(pig_otel_validation_facts, {stream_observed, Trace,
                opentelemetry:timestamp_to_nano(opentelemetry:timestamp())}),
            First
    end.

content_request(Path, Streaming) ->
    Api = api(list_to_binary(Path)),
    {ok, Data} = file:read_file(filename:join("test_data/content", Api ++ "-request.json")),
    %% Keep fixture bytes otherwise identical; only the streaming switch changes.
    binary:replace(Data, <<"\"stream\":false">>,
                   iolist_to_binary(["\"stream\":", atom_to_list(Streaming)]), [global]).

upstream(_Listener, 0) -> ok;
upstream(Listener, N) ->
    {ok, Socket} = gen_tcp:accept(Listener, 10000),
    try
        {ok, {http_request, 'POST', {abs_path, Path}, _}} = gen_tcp:recv(Socket, 0, 10000),
        Headers = headers(Socket, []),
        Length = binary_to_integer(proplists:get_value(<<"content-length">>, Headers)),
        ok = inet:setopts(Socket, [{packet, raw}]),
        {ok, Body} = gen_tcp:recv(Socket, Length, 10000),
        case binary:match(Body, <<"CAPTURE_ALLOWED_">>) of
            nomatch -> true = binary:match(Body, <<"PRIVATE_PROMPT">>) =/= nomatch;
            _ -> ok
        end,
        [<<"Bearer PRIVATE_API_KEY">>] = proplists:get_all_values(<<"authorization">>, Headers),
        [] = proplists:get_all_values(<<"baggage">>, Headers),
        [Traceparent] = proplists:get_all_values(<<"traceparent">>, Headers),
        States = proplists:get_all_values(<<"tracestate">>, Headers),
        true = length(States) =< 1,
        false = lists:member(<<"stale-duplicate">>, States),
        ets:insert(pig_otel_validation_facts, {outbound, Path, Traceparent}),
        Streaming = maps:get(<<"stream">>, json:decode(Body), false),
        [{fixture_mode, FixtureMode}] = ets:lookup(pig_otel_validation_facts, fixture_mode),
        case FixtureMode of ordinary -> ok;
            _ -> verify_content_forwarding(api(Path), Streaming, Body)
        end,
        Trace = binary:part(Traceparent, 3, 32),
        AttemptNumber = 1 + length([ok || {forwarded_body, _, _, TP} <-
            ets:tab2list(pig_otel_validation_facts),
            binary:part(TP, 3, 32) =:= Trace]),
        ets:insert(pig_otel_validation_facts, {forwarded_body, Path, Body, Traceparent}),
        RetryFailure = FixtureMode =:= content_retry andalso AttemptNumber rem 2 =:= 1,
        {Type, Reply} = response(Path, Streaming, FixtureMode),
        First = case FixtureMode of
            Mode when Mode =/= ordinary, Streaming -> fixture("content/" ++ api(Path) ++ "-stream-first.sse");
            _ -> first_chunk(Path, Streaming)
        end,
        case RetryFailure of
            true ->
                Failure = <<"PRIVATE_RETRY_ENVELOPE">>,
                ok = gen_tcp:send(Socket, ["HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: ",
                    integer_to_list(byte_size(Failure)), "\r\nConnection: close\r\n\r\n", Failure]);
            false ->
                %% The interrupted fixture declares the full upstream entity,
                %% then sends only First and waits for the downstream close.
                %% This makes the upstream body genuinely incomplete.
                ResponseLength = byte_size(First) + byte_size(Reply),
                ok = gen_tcp:send(Socket, ["HTTP/1.1 200 OK\r\nContent-Type: ", Type,
                    "\r\nContent-Length: ", integer_to_list(ResponseLength),
                    "\r\nConnection: close\r\n\r\n"]),
                case Streaming of
                    false -> ok;
                    true ->
                        ets:insert(pig_otel_validation_facts, {stream_release, Path, self()}),
                        ok = gen_tcp:send(Socket, First),
                        case FixtureMode of
                            content_interrupt ->
                                receive {cancel, Path} -> ok
                                after 10000 -> error(downstream_receipt_timeout) end;
                            _ ->
                                receive {release, Path} -> ok
                                after 10000 -> error(downstream_receipt_timeout) end
                        end,
                        ets:delete_object(pig_otel_validation_facts, {stream_release, Path, self()})
                end,
                case FixtureMode of
                    content_interrupt -> ok;
                    _ -> ok = gen_tcp:send(Socket, Reply)
                end
        end
    after gen_tcp:close(Socket) end,
    upstream(Listener, N - 1).

headers(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, http_eoh} -> lists:reverse(Acc);
        {ok, {http_header, _, Key, _, Value}} ->
            K = if is_atom(Key) -> atom_to_binary(Key, utf8); true -> Key end,
            headers(Socket, [{string:lowercase(K), Value} | Acc])
    end.
verify_content_forwarding(Api, Streaming, Body) ->
    Name = case Api of "chat" -> "chat-request.json"; "responses" -> "responses-request.json" end,
    {ok, Original} = file:read_file(filename:join("test_data/content", Name)),
    Expected0 = json:decode(Original),
    Expected1 = Expected0#{<<"stream">> => Streaming},
    Expected = case {Api, Streaming} of
        {"chat", true} -> Expected1#{<<"stream_options">> => #{<<"include_usage">> => true}};
        _ -> Expected1
    end,
    Expected = json:decode(Body),
    ok.

first_chunk(_, false) -> <<>>;
first_chunk(Path, true) -> fixture(api(Path) ++ "-stream-first.sse").

response(Path, false, ordinary) ->
    {"application/json", fixture(api(Path) ++ "-sync.json")};
response(Path, true, ordinary) ->
    {"text/event-stream", fixture(api(Path) ++ "-stream-final.sse")};
response(Path, false, content) ->
    {"application/json", fixture("content/" ++ api(Path) ++ "-response.json")};
response(Path, true, content) ->
    {"text/event-stream", fixture("content/" ++ api(Path) ++ "-stream-final.sse")};
response(Path, true, content_malformed) ->
    {"text/event-stream", fixture("content/" ++ api(Path) ++ "-stream-malformed-final.sse")};
response(Path, Streaming, content_retry) -> response(Path, Streaming, content);
response(Path, Streaming, content_interrupt) -> response(Path, Streaming, content).

api(<<"/v1/responses">>) -> "responses";
api(_) -> "chat".
fixture(Name) ->
    {ok, Data} = file:read_file(filename:join("test_data", Name)),
    Data.
