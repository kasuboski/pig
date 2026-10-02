%% Loopback HTTP/protobuf receiver. It is not an exporter implementation:
%% decoding uses the official exporter's generated protobuf module.
-module(pig_otel_validation_receiver).
-export([start/1, endpoint/1, snapshot/2, stop/1]).

start(EvidenceFile) ->
    {ok, Listener} = gen_tcp:listen(0, [binary, {packet, http_bin},
                         {active, false}, {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Listener),
    {Pid, Mon} = spawn_monitor(fun() ->
        put(evidence_prefix, filename:rootname(EvidenceFile)),
        put(batch_count, 0),
        receive start -> loop(Listener, [], undefined) end
    end),
    ok = gen_tcp:controlling_process(Listener, Pid),
    Pid ! start,
    {Pid, Mon, Port}.
endpoint({_, _, Port}) -> "http://127.0.0.1:" ++ integer_to_list(Port).

snapshot({Pid, Mon, _}, Expected) ->
    Ref = make_ref(),
    Pid ! {snapshot, self(), Ref, Expected},
    receive
        {Ref, Spans} -> Spans;
        {'DOWN', Mon, process, Pid, Reason} -> error({receiver_failed, Reason})
    after 15000 -> error({receiver_ack_timeout, Expected}) end.

stop({Pid, Mon, _}) ->
    Pid ! stop,
    receive {'DOWN', Mon, process, Pid, _} -> ok
    after 1000 -> exit(Pid, kill), receive {'DOWN', Mon, process, Pid, _} -> ok end end.

%% A linked acceptor uses only public socket APIs and leaves the receiver
%% responsive to snapshot/stop messages without timeout polling.
loop(Listener, Acc, Waiter) ->
    Receiver = self(),
    _ = spawn_link(fun() ->
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
            New = Acc ++ decode(Request),
            maybe_evidence(Request, New),
            loop(Listener, New, maybe_ack(New, Waiter));
        {snapshot, From, ReplyRef, Expected} ->
            NewWaiter = maybe_ack(Acc, {From, ReplyRef, Expected}),
            wait(Listener, Acc, NewWaiter);
        stop -> gen_tcp:close(Listener)
    end.
maybe_ack(_, undefined) -> undefined;
maybe_ack(Spans, {From, Ref, Expected}) when length(Spans) >= Expected ->
    From ! {Ref, Spans}, undefined;
maybe_ack(_, Waiter) -> Waiter.

receive_request(Socket) ->
    try
        {ok, {http_request, 'POST', {abs_path, <<"/v1/traces">>}, _}} = gen_tcp:recv(Socket, 0, 10000),
        Headers = headers(Socket, #{}),
        <<"application/x-protobuf">> = maps:get(<<"content-type">>, Headers),
        Length = binary_to_integer(maps:get(<<"content-length">>, Headers)),
        ok = inet:setopts(Socket, [{packet, raw}]),
        {ok, Body} = gen_tcp:recv(Socket, Length, 10000),
        write_protobuf(Body),
        Request = opentelemetry_exporter_trace_service_pb:decode_msg(Body, export_trace_service_request),
        true = pig_otel_validation_verify:safe_metadata(Request),
        ok = gen_tcp:send(Socket, <<"HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\nContent-Length: 0\r\nConnection: close\r\n\r\n">>),
        Request
    after gen_tcp:close(Socket) end.
headers(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0, 10000) of
        {ok, http_eoh} -> Acc;
        {ok, {http_header, _, Key, _, Value}} ->
            K = if is_atom(Key) -> atom_to_binary(Key, utf8); true -> Key end,
            headers(Socket, Acc#{string:lowercase(K) => Value})
    end.

decode(#{resource_spans := Resources}) ->
    lists:flatmap(fun(#{resource := Resource, scope_spans := Scopes}) ->
        #{<<"service.name">> := <<"pig-otel-local-validation">>} = attributes(maps:get(attributes, Resource)),
        lists:flatmap(fun(#{scope := Scope, spans := Spans}=ScopeSpans) ->
            [span(S, Scope, maps:get(schema_url, ScopeSpans, <<>>)) || S <- Spans]
        end, Scopes)
    end, Resources).
span(S, Scope, Schema) ->
    #{trace_id => binary:encode_hex(maps:get(trace_id, S), lowercase),
      span_id => binary:encode_hex(maps:get(span_id, S), lowercase),
      parent_span_id => binary:encode_hex(maps:get(parent_span_id, S), lowercase),
      name => maps:get(name, S), kind => kind(maps:get(kind, S)),
      status => status(maps:get(status, S, #{})),
      attributes => attributes(maps:get(attributes, S, [])),
      start => maps:get(start_time_unix_nano, S),
      'end' => maps:get(end_time_unix_nano, S),
      scope => maps:get(name, Scope), version => maps:get(version, Scope, <<>>),
      schema => Schema, events => maps:get(events, S, []), links => maps:get(links, S, [])}.
kind('SPAN_KIND_INTERNAL') -> internal;
kind('SPAN_KIND_CLIENT') -> client;
kind('SPAN_KIND_SERVER') -> server.
status(#{code := 'STATUS_CODE_ERROR'}) -> error;
status(#{code := 'STATUS_CODE_OK'}) -> ok;
status(_) -> unset.
attributes(Attributes) -> maps:from_list([{K, value(V)} || #{key := K, value := V} <- Attributes]).
value(#{value := {array_value, #{values := Values}}}) -> [value(V) || V <- Values];
value(#{value := {_, V}}) -> V.
maybe_evidence(Request, Spans) ->
    case os:getenv("PIG_OTEL_EVIDENCE_DIR") of
        false -> ok;
        Dir ->
            Prefix = get(evidence_prefix),
            ok = file:write_file(filename:join(Dir, Prefix ++ "-decoded.term"), io_lib:format("~tp.~n", [Request])),
            ok = file:write_file(filename:join(Dir, Prefix ++ "-snapshot.term"), io_lib:format("~tp.~n", [Spans]))
    end.
write_protobuf(Body) ->
    Count = get(batch_count) + 1,
    put(batch_count, Count),
    case os:getenv("PIG_OTEL_EVIDENCE_DIR") of
        false -> ok;
        Dir ->
            Name = get(evidence_prefix) ++ "-batch-" ++ integer_to_list(Count) ++ ".pb",
            ok = file:write_file(filename:join(Dir, Name), Body)
    end.
