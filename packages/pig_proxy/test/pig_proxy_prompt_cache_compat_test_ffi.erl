-module(pig_proxy_prompt_cache_compat_test_ffi).
-export([start_capture_upstream/0, await_body/1, stop_capture_upstream/1]).

start_capture_upstream() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}, {ip, {127,0,0,1}}]),
    {ok, {{127,0,0,1}, Port}} = inet:sockname(Listen),
    Parent = self(),
    Pid = spawn(fun() -> serve(Listen, Parent) end),
    {ok, {Port, Pid}}.

await_body(Pid) ->
    Ref = make_ref(),
    Pid ! {await, self(), Ref},
    receive {Ref, Result} -> Result after 5000 -> {error, nil} end.

stop_capture_upstream(Pid) ->
    Pid ! stop,
    nil.

serve(Listen, _Parent) ->
    serve_loop(Listen, []).

serve_loop(Listen, Captured) ->
    receive
        {await, From, Ref} ->
            case Captured of
                [Body | Rest] -> From ! {Ref, {ok, Body}}, serve_loop(Listen, Rest);
                [] -> From ! {Ref, {error, nil}}, serve_loop(Listen, Captured)
            end;
        stop -> gen_tcp:close(Listen), nil
    after 0 ->
        case gen_tcp:accept(Listen, 200) of
            {ok, Socket} ->
                Request = recv_request(Socket, <<>>),
                Body = request_body(Request),
                Fields = json:decode(Body),
                HasCache = maps:is_key(<<"prompt_cache_options">>, Fields),
                Supported = maps:get(<<"model">>, Fields, <<>>) =:= <<"keep-model">>,
                Status = case HasCache andalso not Supported of true -> 400; false -> 200 end,
                ResponseBody = case {Status, maps:get(<<"stream">>, Fields, false)} of
                    {400, _} -> <<"{\"message\":\"prompt_cache_options is not supported on this model\",\"type\":\"invalid_request_error\",\"param\":\"prompt_cache_options\",\"code\":\"invalid_parameter\"}">>;
                    {200, false} -> <<"{\"id\":\"ok\",\"status\":\"completed\"}">>;
                    {200, true} -> <<"event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"ok\",\"status\":\"completed\"}}\n\n">>
                end,
                Reason = case Status of 200 -> "OK"; _ -> "Bad Request" end,
                _ = gen_tcp:send(Socket, ["HTTP/1.1 ", integer_to_list(Status), " ", Reason,
                    "\r\nContent-Type: ", content_type(Body), "\r\nConnection: close\r\nContent-Length: ",
                    integer_to_list(byte_size(ResponseBody)), "\r\n\r\n", ResponseBody]),
                _ = gen_tcp:close(Socket),
                serve_loop(Listen, Captured ++ [Body]);
            {error, timeout} -> serve_loop(Listen, Captured);
            {error, closed} -> nil;
            {error, _} -> serve_loop(Listen, Captured)
        end
    end.

content_type(Body) ->
    case maps:get(<<"stream">>, json:decode(Body), false) of false -> "application/json"; true -> "text/event-stream" end.

recv_request(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        {Pos, 4} ->
            HeadEnd = Pos + 4,
            <<Headers:HeadEnd/binary, Rest/binary>> = Acc,
            Length = content_length(Headers),
            case byte_size(Rest) >= Length of
                true -> <<_:HeadEnd/binary, Body:Length/binary, _/binary>> = Acc, Body;
                false -> case gen_tcp:recv(Socket, 0, 5000) of {ok, Data} -> recv_request(Socket, <<Acc/binary, Data/binary>>); _ -> <<>> end
            end;
        nomatch -> case gen_tcp:recv(Socket, 0, 5000) of {ok, Data} -> recv_request(Socket, <<Acc/binary, Data/binary>>); _ -> <<>> end
    end.

content_length(Headers) ->
    Lines = binary:split(Headers, <<"\r\n">>, [global]),
    case [binary_to_integer(trim(Value)) || Line <- Lines,
        [Name, Value] <- [binary:split(Line, <<":">>)],
        string:lowercase(binary_to_list(Name)) =:= "content-length"] of
        [N | _] -> N;
        [] -> 0
    end.

trim(Value) -> list_to_binary(string:trim(binary_to_list(Value))).

request_body(Body) -> Body.
