%% Local upstream + real proxy HTTP client. No paid APIs or external endpoints.
-module(pig_otel_validation_http).
-export([check_proxy/1, check_proxy_sync/1]).
-include_lib("opentelemetry/include/otel_span.hrl").

check_proxy(Start) ->
    check_proxy_matrix(Start, [{"/v1/chat/completions", false, 1},
                               {"/v1/responses", false, 2},
                               {"/v1/chat/completions", true, 3},
                               {"/v1/responses", true, 4}]).

check_proxy_sync(Start) ->
    check_proxy_matrix(Start, [{"/v1/chat/completions", false, 1},
                               {"/v1/responses", false, 2}]).

check_proxy_matrix(Start, Cases) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {packet, http_bin},
        {active, false}, {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, UpstreamPort}} = inet:sockname(Listener),
    {ok, Reservation} = gen_tcp:listen(0, [{ip, {127,0,0,1}}]),
    {ok, {_, ProxyPort}} = inet:sockname(Reservation),
    gen_tcp:close(Reservation),
    Parent = self(),
    {Upstream, UpMon} = spawn_monitor(fun() -> upstream(Listener, length(Cases)) end),
    Ref = make_ref(),
    {Proxy, ProxyMon} = spawn_monitor(fun() ->
        Start(ProxyPort, iolist_to_binary(["http://127.0.0.1:", integer_to_list(UpstreamPort), "/v1"])),
        Parent ! {Ref, ready},
        receive stop -> exit(shutdown) end
    end),
    try
        receive
            {Ref, ready} -> ok;
            {'DOWN', ProxyMon, process, Proxy, Why} -> error({proxy_start_failed, Why})
        after 10000 -> error(proxy_start_timeout) end,
        lists:foreach(fun({Path, Streaming, Index}) ->
            request(ProxyPort, Path, Streaming, Index)
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
        erlang:demonitor(UpMon, [flush])
    end,
    nil.

request(Port, Path, Streaming, Index) ->
    Body = iolist_to_binary(["{\"model\":\"fixture_model\",\"stream\":", atom_to_list(Streaming),
                ",\"messages\":[{\"role\":\"user\",\"content\":\"PRIVATE_PROMPT\"}]} "]),
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
        true ->
            {ok, RequestId} = httpc:request(post,
                {Url, Headers, "application/json", Body}, [{timeout, 10000}],
                [{body_format, binary}, {sync, false}, {stream, self}]),
            try client_stream(RequestId, list_to_binary(Path), Trace, [], false)
            after httpc:cancel_request(RequestId) end
    end,
    true = byte_size(Response) > 0,
    ets:insert(pig_otel_validation_facts, {ingress, Trace, Parent,
                                        list_to_binary(Path), Streaming}),
    ok.

client_stream(Id, Path, Trace, Acc, Seen) ->
    receive
        {http, {Id, stream_start, _Headers}} -> client_stream(Id, Path, Trace, Acc, Seen);
        {http, {Id, stream, Chunk}} when byte_size(Chunk) > 0 ->
            case Seen of
                true -> ok;
                false ->
                    %% Actual downstream first body receipt releases late upstream
                    %% usage. This is an ACK barrier, not a scheduling sleep.
                    Timestamp = opentelemetry:timestamp_to_nano(opentelemetry:timestamp()),
                    ets:insert(pig_otel_validation_facts, {stream_observed, Trace, Timestamp}),
                    [{mode, Mode}] = ets:lookup(pig_otel_validation_facts, mode),
                    case Mode of
                        recording ->
                            TraceId = binary_to_integer(Trace, 16),
                            [] = [S || S=#span{trace_id=T} <- ets:tab2list(pig_otel_validation_spans), T =:= TraceId];
                        _ -> ok
                    end,
                    [{stream_release, Path, Upstream}] = ets:lookup(pig_otel_validation_facts, stream_release),
                    Upstream ! {release, Path}
            end,
            client_stream(Id, Path, Trace, [Chunk | Acc], true);
        {http, {Id, stream_end, _Headers}} ->
            true = Seen,
            iolist_to_binary(lists:reverse(Acc));
        {http, {Id, {error, Reason}}} -> error({stream_client_error, Reason});
        {http, {Id, Other}} -> error({unexpected_stream_reply, Other})
    after 10000 -> error(downstream_chunk_timeout) end.

upstream(_Listener, 0) -> ok;
upstream(Listener, N) ->
    {ok, Socket} = gen_tcp:accept(Listener, 10000),
    try
        {ok, {http_request, 'POST', {abs_path, Path}, _}} = gen_tcp:recv(Socket, 0, 10000),
        Headers = headers(Socket, []),
        Length = binary_to_integer(proplists:get_value(<<"content-length">>, Headers)),
        ok = inet:setopts(Socket, [{packet, raw}]),
        {ok, Body} = gen_tcp:recv(Socket, Length, 10000),
        true = binary:match(Body, <<"PRIVATE_PROMPT">>) =/= nomatch,
        [<<"Bearer PRIVATE_API_KEY">>] = proplists:get_all_values(<<"authorization">>, Headers),
        [] = proplists:get_all_values(<<"baggage">>, Headers),
        [Traceparent] = proplists:get_all_values(<<"traceparent">>, Headers),
        States = proplists:get_all_values(<<"tracestate">>, Headers),
        true = length(States) =< 1,
        false = lists:member(<<"stale-duplicate">>, States),
        ets:insert(pig_otel_validation_facts, {outbound, Path, Traceparent}),
        Streaming = binary:match(Body, <<"\"stream\":true">>) =/= nomatch,
        {Type, Reply} = response(Path, Streaming),
        First = first_chunk(Path, Streaming),
        ok = gen_tcp:send(Socket, ["HTTP/1.1 200 OK\r\nContent-Type: ", Type,
            "\r\nContent-Length: ", integer_to_list(byte_size(First) + byte_size(Reply)),
            "\r\nConnection: close\r\n\r\n"]),
        case Streaming of
            false -> ok;
            true ->
                ets:insert(pig_otel_validation_facts, {stream_release, Path, self()}),
                ok = gen_tcp:send(Socket, First),
                receive {release, Path} -> ok
                after 10000 -> error(downstream_receipt_timeout) end,
                ets:delete_object(pig_otel_validation_facts, {stream_release, Path, self()})
        end,
        ok = gen_tcp:send(Socket, Reply)
    after gen_tcp:close(Socket) end,
    upstream(Listener, N - 1).

headers(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, http_eoh} -> lists:reverse(Acc);
        {ok, {http_header, _, Key, _, Value}} ->
            K = if is_atom(Key) -> atom_to_binary(Key, utf8); true -> Key end,
            headers(Socket, [{string:lowercase(K), Value} | Acc])
    end.
first_chunk(_, false) -> <<>>;
first_chunk(Path, true) -> fixture(api(Path) ++ "-stream-first.sse").

response(Path, false) ->
    {"application/json", fixture(api(Path) ++ "-sync.json")};
response(Path, true) ->
    {"text/event-stream", fixture(api(Path) ++ "-stream-final.sse")}.

api(<<"/v1/responses">>) -> "responses";
api(_) -> "chat".
fixture(Name) ->
    {ok, Data} = file:read_file(filename:join("test_data", Name)),
    Data.
