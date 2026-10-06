-module(pig_proxy_model_catalog_retry_test_ffi).
-export([start_failure_then_success_server/0, stop_failure_then_success_server/1]).

start_failure_then_success_server() ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                    {ip, {127,0,0,1}}]),
    {ok, {{127,0,0,1}, Port}} = inet:sockname(Listen),
    Pid = spawn(fun() -> receive {serve, Socket} -> serve(Socket, 0) end end),
    ok = gen_tcp:controlling_process(Listen, Pid),
    Pid ! {serve, Listen},
    {ok, {Port, Pid}}.

stop_failure_then_success_server(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    nil.

serve(Listen, Count) ->
    case gen_tcp:accept(Listen, 20000) of
        {ok, Socket} ->
            _ = gen_tcp:recv(Socket, 0, 5000),
            {Status, Body} = case Count of
                0 -> {503, <<"unavailable">>};
                _ -> {200, <<"{\"openai\":{\"id\":\"openai\",\"models\":{\"openai/recovered\":{\"id\":\"openai/recovered\",\"cost\":{\"input\":1}}}}}">>}
            end,
            Response = ["HTTP/1.1 ", integer_to_list(Status),
                        case Status of 200 -> " OK\r\n"; _ -> " Service Unavailable\r\n" end,
                        "Content-Type: application/json\r\nConnection: close\r\n",
                        "Content-Length: ", integer_to_list(byte_size(Body)), "\r\n\r\n", Body],
            _ = gen_tcp:send(Socket, Response),
            _ = gen_tcp:close(Socket),
            case Count of
                0 -> serve(Listen, 1);
                _ -> gen_tcp:close(Listen)
            end;
        {error, timeout} -> gen_tcp:close(Listen);
        {error, _} -> gen_tcp:close(Listen)
    end.
