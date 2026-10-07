-module(pig_proxy_model_catalog_admission_test_ffi).
-export([start_gated_catalog_server/0, await_catalog_request/0,
         release_catalog_response/1, stop_gated_catalog_server/1]).

start_gated_catalog_server() ->
    Owner = self(),
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true},
                                    {ip, {127,0,0,1}}]),
    {ok, {{127,0,0,1}, Port}} = inet:sockname(Listen),
    Pid = spawn(fun() -> gated_serve(Listen, Owner) end),
    {ok, {Port, Pid}}.

await_catalog_request() ->
    receive {catalog_requested, _Pid} -> true after 5000 -> false end.

release_catalog_response(Pid) -> Pid ! release_catalog, nil.

stop_gated_catalog_server(Pid) ->
    unlink(Pid),
    exit(Pid, kill),
    nil.

gated_serve(Listen, Owner) ->
    case gen_tcp:accept(Listen, 10000) of
        {ok, Socket} ->
            _ = gen_tcp:recv(Socket, 0, 5000),
            Owner ! {catalog_requested, self()},
            receive
                release_catalog ->
                    Body = <<"{\"openai\":{\"id\":\"openai\",\"models\":{\"openai/priced\":{\"id\":\"openai/priced\",\"cost\":{\"input\":2,\"output\":10}}}}}">>,
                    Response = ["HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
                                integer_to_list(byte_size(Body)), "\r\n\r\n", Body],
                    _ = gen_tcp:send(Socket, Response),
                    _ = gen_tcp:close(Socket),
                    gen_tcp:close(Listen);
                stop -> gen_tcp:close(Socket), gen_tcp:close(Listen)
            after 10000 -> gen_tcp:close(Socket), gen_tcp:close(Listen)
            end;
        {error, _} -> gen_tcp:close(Listen)
    end.
