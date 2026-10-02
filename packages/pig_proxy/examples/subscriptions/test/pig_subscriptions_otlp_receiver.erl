%% An independent loopback OTLP/HTTP receiver. No exporter internals are mocked.
-module(pig_subscriptions_otlp_receiver).
-export([start/0, endpoint/1, assert_no_export/1, verify/2, stop/1]).

start() ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {packet, http_bin}, {active, false},
                                          {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    {Pid, Mon} = spawn_monitor(fun() -> receive start -> loop(Listener, []) end end),
    ok = gen_tcp:controlling_process(Listener, Pid),
    Pid ! start,
    {Pid, Mon, Port}.

endpoint({_, _, Port}) -> "http://127.0.0.1:" ++ integer_to_list(Port) ++ "/v1/traces".

assert_no_export({Pid, Mon, _}) ->
    Ref = make_ref(),
    Pid ! {peek, self(), Ref},
    receive
        {Ref, 0} -> ok;
        {Ref, Count} -> error({scheduled_export_masked_shutdown_gate, Count});
        {'DOWN', Mon, process, Pid, Reason} -> error({otlp_receiver_failed, Reason})
    after 1000 -> error(otlp_receiver_snapshot_timeout)
    end.

verify({Pid, Mon, _}, Capture) ->
    Ref = make_ref(),
    Pid ! {snapshot, self(), Ref, 20},
    receive
        {Ref, Spans} -> pig_subscriptions_otlp_verify:check(Spans, Capture);
        {'DOWN', Mon, process, Pid, Reason} -> error({otlp_receiver_failed, Reason})
    after 15000 ->
        Pid ! {peek, self(), Ref},
        receive {Ref, Count} -> error({otlp_receiver_missing_spans_after_shutdown, Count, 20})
        after 1000 -> error(otlp_receiver_snapshot_timeout) end
    end.

stop({Pid, Mon, _}) ->
    %% verify may already have consumed the original DOWN on a receiver error.
    erlang:demonitor(Mon, [flush]),
    StopMonitor = erlang:monitor(process, Pid),
    Pid ! stop,
    receive {'DOWN', StopMonitor, process, Pid, _} -> ok
    after 1000 ->
        exit(Pid, kill),
        receive {'DOWN', StopMonitor, process, Pid, _} -> ok end
    end.

loop(Listener, Acc) -> loop(Listener, Acc, undefined).

loop(Listener, Acc, Waiter) ->
    Receiver = self(),
    spawn_link(fun() ->
        case gen_tcp:accept(Listener) of
            {ok, Socket} ->
                ok = gen_tcp:controlling_process(Socket, Receiver),
                Receiver ! {accepted, Socket};
            {error, closed} -> ok;
            {error, Reason} -> error({accept_failed, Reason})
        end
    end),
    wait(Listener, Acc, Waiter).

wait(Listener, Acc, Waiter) ->
    receive
        {accepted, Socket} ->
            Request = receive_request(Socket),
            Decoded = decode(Request),
            io:format("OTLP receiver got ~p spans on ~p~n", [length(Decoded), element(1, Request)]),
            Next = Acc ++ Decoded,
            NextWaiter = case Waiter of
                {From, Ref, Expected} when length(Next) >= Expected ->
                    From ! {Ref, Next}, undefined;
                _ -> Waiter
            end,
            loop(Listener, Next, NextWaiter);
        {snapshot, From, Ref, Expected} when length(Acc) >= Expected ->
            From ! {Ref, Acc},
            wait(Listener, Acc, Waiter);
        {snapshot, From, Ref, Expected} ->
            wait(Listener, Acc, {From, Ref, Expected});
        {peek, From, Ref} -> From ! {Ref, length(Acc)}, wait(Listener, Acc, Waiter);
        stop -> gen_tcp:close(Listener)
    end.

receive_request(Socket) ->
    try
        %% Decode and ACK even a wrong path, then fail the wire-path assertion
        %% after collecting the full export rather than hiding other defects.
        {ok, {http_request, 'POST', {abs_path, Path}, _}} = gen_tcp:recv(Socket, 0, 10000),
        Headers = headers(Socket, #{}),
        <<"Bearer synthetic-latitude-key">> = maps:get(<<"authorization">>, Headers),
        <<"synthetic-project">> = maps:get(<<"x-latitude-project">>, Headers),
        <<"application/x-protobuf">> = maps:get(<<"content-type">>, Headers),
        false = maps:is_key(<<"content-encoding">>, Headers),
        Length = binary_to_integer(maps:get(<<"content-length">>, Headers)),
        ok = inet:setopts(Socket, [{packet, raw}]),
        {ok, Body} = gen_tcp:recv(Socket, Length, 10000),
        Request = opentelemetry_exporter_trace_service_pb:decode_msg(Body, export_trace_service_request),
        ok = gen_tcp:send(Socket, <<"HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\nContent-Length: 0\r\nConnection: close\r\n\r\n">>),
        {Path, Request}
    after gen_tcp:close(Socket) end.

headers(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, http_eoh} -> Acc;
        {ok, {http_header, _, Key, _, Value}} ->
            K = if is_atom(Key) -> atom_to_binary(Key, utf8); true -> Key end,
            headers(Socket, Acc#{string:lowercase(K) => Value})
    end.

decode({Path, #{resource_spans := Resources}}) ->
    lists:flatmap(fun(#{resource := Resource, scope_spans := Scopes}) ->
        #{<<"service.name">> := <<"pig-proxy-subscriptions">>} = attributes(maps:get(attributes, Resource)),
        lists:flatmap(fun(#{scope := Scope, spans := Spans}) ->
            <<"pig_proxy">> = maps:get(name, Scope),
            [#{wire_path => Path, trace_id => maps:get(trace_id, S), span_id => maps:get(span_id, S),
               parent_span_id => maps:get(parent_span_id, S),
               kind => maps:get(kind, S), name => maps:get(name, S),
               attributes => attributes(maps:get(attributes, S, [])),
               start => maps:get(start_time_unix_nano, S),
               'end' => maps:get(end_time_unix_nano, S),
               status => maps:get(status, S, #{}),
               events => maps:get(events, S, []), links => maps:get(links, S, [])} || S <- Spans]
        end, Scopes)
    end, Resources).

attributes(Attrs) -> maps:from_list([{K, value(V)} || #{key := K, value := V} <- Attrs]).
value(#{value := {array_value, #{values := Values}}}) -> [value(V) || V <- Values];
value(#{value := {_, V}}) -> V.
