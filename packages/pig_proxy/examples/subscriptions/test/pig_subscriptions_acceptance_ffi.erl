-module(pig_subscriptions_acceptance_ffi).
-export([run/0]).

run() ->
    process_flag(trap_exit, true),
    application:ensure_all_started(inets),
    Example = example_dir(filename:dirname(filename:absname(code:which(?MODULE)))),
    Erl = os:find_executable("erl"),
    Auth = filename:join([tmp_dir(), "pig-subscriptions-no-auth-" ++ integer_to_list(erlang:unique_integer([positive]))]),
    false = filelib:is_file(Auth),
    GleamEbins = filelib:wildcard(filename:join(Example, "build/dev/erlang/*/ebin")),
    DependencyEbens = filelib:wildcard(filename:join(Example, "host/_build/default/lib/*/ebin")),
    %% Direct `gleam test` does not add the host-only decoder dependencies.
    ok = code:add_paths(DependencyEbens),
    Paths = lists:append([["-pa", P] || P <- GleamEbins ++ DependencyEbens]),
    %% Keep the periodic timer out of the gate: only shutdown can export.
    Args = ["-noshell"] ++ Paths ++ ["-eval",
        "application:set_env(opentelemetry, span_processor, {otel_batch_processor, #{scheduled_delay_ms => 60000}}), subscriptions@host:main()."],
    lists:foreach(fun(Capture) -> run_host(Capture, Erl, Args, Auth) end, [false, default, outage]),
    ok.

run_host(Capture, Erl, Args, Auth) ->
    Port = free_port(),
    {Codex, CodexPort} = upstream(),
    {Zai, ZaiPort} = upstream(),
    Receiver = pig_subscriptions_otlp_receiver:start(),
    Env =  [{"PIG_CHATGPT_MODELS", "fake-codex"},
           {"PIG_ZAI_MODELS", "fake-zai"}, {"ZAI_API_KEY", "synthetic-zai-key"},
           {"PIG_CHATGPT_BASE_URL", "http://127.0.0.1:" ++ integer_to_list(CodexPort) ++ "/codex"},
           {"PIG_ZAI_BASE_URL", "http://127.0.0.1:" ++ integer_to_list(ZaiPort) ++ "/v1"},
           {"PIG_PROXY_PORT", integer_to_list(Port)},
           {"PIG_PROXY_MODELS_DEV_URL", "http://127.0.0.1:1/catalog"},
           {"PIG_CODEX_AUTH_PATH", Auth},
           {"OPENAI_COMPAT_CODEX_TOKEN", binary_to_list(fake_jwt())},
           {"PIG_PROXY_CAPTURE_CONVERSATION", case Capture of default -> false; _ -> "false" end},
           {"PIG_LATITUDE_ENABLED", "true"},
           {"LATITUDE_API_KEY", "synthetic-latitude-key"},
           {"LATITUDE_PROJECT", "synthetic-project"},
           %% Host-level scrubbing must beat OS overrides even without scripts.
           {"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://127.0.0.1:1/wrong"},
           {"OTEL_EXPORTER_OTLP_TRACES_HEADERS", "Authorization=wrong-key"},
           {"OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", "grpc"},
           {"OTEL_EXPORTER_OTLP_TRACES_COMPRESSION", "gzip"},
           {"OTEL_TRACES_EXPORTER", "console"},
           {"OTEL_SDK_DISABLED", "true"},
           {"PIG_LATITUDE_ENDPOINT", case Capture of
               outage -> "http://127.0.0.1:1/v1/traces";
               _ -> pig_subscriptions_otlp_receiver:endpoint(Receiver)
           end}],
    Host = open_port({spawn_executable, Erl}, [{args, Args}, {env, Env}, exit_status, use_stdio, stderr_to_stdout, {line, 4096}]),
    try
        await_started(Host, <<>>),
        {200, _} = request(Port, get, "/health", <<>>, []),
        {404, _} = request(Port, get, "/not-a-route", <<>>, []),
        {404, _} = request(Port, post, "/v1/unknown", <<"{}">>, []),
        {400, _} = request(Port, post, "/v1/responses", <<"{}">>, json_headers()),
        {400, _} = request(Port, post, "/v1/responses", <<"{\"model\":17}">>, json_headers()),
        {503, _} = request(Port, post, "/v1/responses", <<"{\"model\":\"not-configured\"}">>, json_headers()),
        {503, _} = request(Port, post, "/v1/responses", <<"{\"model\":\"fake-zai\"}">>, json_headers()),
        {503, _} = request(Port, post, "/v1/chat/completions", <<"{\"model\":\"fake-codex\"}">>, json_headers()),
        0 = count(Codex), 0 = count(Zai),
        Responses = <<"{\"model\":\"fake-codex\",\"stream\":false,\"store\":false,\"instructions\":\"test\",\"input\":\"codex-buffered-secret\"}">>,
        {200, BufferedResponses} = request(Port, post, "/v1/responses", Responses, traced_headers(17)),
        true = binary:match(BufferedResponses, <<"responses-output-marker">>) =/= nomatch,
        CodexRequest = assert_request(Codex, <<"/codex/responses">>, <<"Bearer ", (fake_jwt())/binary>>, <<"fake-codex">>, false),
        assert_header(CodexRequest, <<"chatgpt-account-id">>, <<"synthetic-account">>),
        assert_not_header(CodexRequest, <<"x-api-key">>),
        assert_body_contains(CodexRequest, <<"codex-buffered-secret">>),
        Responses = maps:get(body, CodexRequest),
        CodexStream = <<"{\"model\":\"fake-codex\",\"stream\":true,\"store\":false,\"instructions\":\"test\",\"input\":\"codex-stream-secret\"}">>,
        {200, StreamResponses} = request(Port, post, "/v1/responses", CodexStream, traced_headers(18)),
        true = binary:match(StreamResponses, <<"response.completed">>) =/= nomatch,
        true = binary:match(StreamResponses, <<"responses-output-marker">>) =/= nomatch,
        CodexStreamRequest = assert_request(Codex, <<"/codex/responses">>, <<"Bearer ", (fake_jwt())/binary>>, <<"fake-codex">>, true),
        assert_body_contains(CodexStreamRequest, <<"codex-stream-secret">>),
        CodexStream = maps:get(body, CodexStreamRequest),
        nomatch = binary:match(maps:get(body, CodexStreamRequest), <<"stream_options">>),
        Chat = <<"{\"model\":\"fake-zai\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"zai-buffered-secret\"}]}">>,
        {200, BufferedChat} = request(Port, post, "/v1/chat/completions", Chat, traced_headers(33)),
        true = binary:match(BufferedChat, <<"chat-output-marker">>) =/= nomatch,
        ZaiRequest = assert_request(Zai, <<"/v1/chat/completions">>, <<"Bearer synthetic-zai-key">>, <<"fake-zai">>, false),
        assert_not_header(ZaiRequest, <<"chatgpt-account-id">>),
        assert_not_header(ZaiRequest, <<"x-api-key">>),
        assert_not_header(ZaiRequest, <<"openai-beta">>),
        Chat = maps:get(body, ZaiRequest),
        assert_body_contains(ZaiRequest, <<"zai-buffered-secret">>),
        ZaiStream = <<"{\"model\":\"fake-zai\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"zai-stream-secret\"}]}">>,
        {200, StreamChat} = request(Port, post, "/v1/chat/completions", ZaiStream, traced_headers(34)),
        true = binary:match(StreamChat, <<"chat-output-marker">>) =/= nomatch,
        ZaiStreamRequest = assert_request(Zai, <<"/v1/chat/completions">>, <<"Bearer synthetic-zai-key">>, <<"fake-zai">>, true),
        assert_body_contains(ZaiStreamRequest, <<"zai-stream-secret">>),
        2 = count(Codex), 2 = count(Zai),
        pig_subscriptions_otlp_receiver:assert_no_export(Receiver),
        stop_host(Host, Port),
        case Capture of
            outage -> ok;
            _ -> pig_subscriptions_otlp_receiver:verify(Receiver, Capture =/= false)
        end,
        case Capture of false -> verify_startup_rejections(Erl, Args, Env, Auth); _ -> ok end,
        ok
    after
        force_cleanup_host(Host),
        stop_upstream(Codex), stop_upstream(Zai),
        pig_subscriptions_otlp_receiver:stop(Receiver)
    end.

example_dir(Dir) ->
    case filelib:is_file(filename:join(Dir, "src/subscriptions/config.gleam")) of
        true -> Dir;
        false ->
            case filename:dirname(Dir) of
                Dir -> error(subscriptions_example_not_found);
                Parent -> example_dir(Parent)
            end
    end.

json_headers() -> [{"content-type", "application/json"},
                   {"authorization", "Bearer synthetic-client-key"},
                   {"x-api-key", "synthetic-client-api-key"},
                   {"chatgpt-account-id", "synthetic-client-account"}].

traced_headers(N) ->
    Trace = io_lib:format("~32.16.0b", [N]),
    [{"traceparent", "00-" ++ lists:flatten(Trace) ++ "-1111111111111111-01"} | json_headers()].

free_port() ->
    {ok, S} = gen_tcp:listen(0, [{ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, P}} = inet:sockname(S), gen_tcp:close(S), P.

tmp_dir() -> case os:getenv("TMPDIR") of false -> "/tmp"; D -> D end.

fake_jwt() ->
    Enc = fun(B) -> base64:encode(B, #{mode => urlsafe, padding => false}) end,
    <<(Enc(<<"{\"alg\":\"none\"}">>))/binary, ".",
      (Enc(<<"{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"synthetic-account\"}}">>))/binary,
      ".synthetic-signature">>.

upstream() ->
    {ok, Socket} = gen_tcp:listen(0, [binary, {packet, http_bin}, {active, false},
                                    {ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, Port}} = inet:sockname(Socket),
    Pid = spawn_link(fun() ->
        accept_request(Socket),
        upstream_loop(Socket, [], 0)
    end),
    {#{pid => Pid, socket => Socket}, Port}.

accept_request(Listener) ->
    Owner = self(),
    spawn_link(fun() ->
        case gen_tcp:accept(Listener) of
            {ok, Client} ->
                Request = read_http(Client),
                Ref = make_ref(),
                Owner ! {upstream_request, Request, self(), Ref},
                receive {recorded, Ref} -> ok end,
                reply(Client, Request);
            {error, closed} -> ok
        end
    end).

upstream_loop(Listener, Requests, Total) ->
    receive
        {upstream_request, Request, Acceptor, Ref} ->
            Acceptor ! {recorded, Ref},
            accept_request(Listener),
            upstream_loop(Listener, Requests ++ [Request], Total + 1);
        {count, From} -> From ! {count, Total}, upstream_loop(Listener, Requests, Total);
        {take, From} ->
            case Requests of
                [Request | Rest] -> From ! {take, Request}, upstream_loop(Listener, Rest, Total);
                [] -> From ! {take, none}, upstream_loop(Listener, [], Total)
            end
    end.

read_http(Socket) ->
    {ok, {http_request, Method, {abs_path, Path}, _}} = gen_tcp:recv(Socket, 0, 5000),
    Headers = read_headers(Socket, #{}),
    Length = binary_to_integer(maps:get(<<"content-length">>, Headers, <<"0">>)),
    ok = inet:setopts(Socket, [{packet, raw}]),
    Body = case Length of 0 -> <<>>; _ -> {ok, B} = gen_tcp:recv(Socket, Length, 5000), B end,
    #{method => Method, path => Path, headers => Headers, body => Body}.

read_headers(Socket, Headers) ->
    case gen_tcp:recv(Socket, 0, 5000) of
        {ok, http_eoh} -> Headers;
        {ok, {http_header, _, Key0, _, Value}} ->
            Key = case is_atom(Key0) of true -> atom_to_binary(Key0, utf8); false -> Key0 end,
            read_headers(Socket, Headers#{string:lowercase(Key) => Value})
    end.

reply(Socket, #{path := Path, body := Body}) ->
    Stream = binary:match(Body, <<"\"stream\":true">>) =/= nomatch,
    Usage = #{<<"input_tokens">> => 11, <<"output_tokens">> => 7,
              <<"input_tokens_details">> => #{<<"cached_tokens">> => 3}},
    ChatUsage = #{<<"prompt_tokens">> => 11, <<"completion_tokens">> => 7,
                  <<"total_tokens">> => 18,
                  <<"prompt_tokens_details">> => #{<<"cached_tokens">> => 3}},
    Response = #{<<"id">> => <<"responses-fixture">>, <<"model">> => <<"fake-codex">>,
                 <<"status">> => <<"completed">>, <<"usage">> => Usage,
                 <<"output">> => [#{<<"type">> => <<"message">>, <<"role">> => <<"assistant">>,
                     <<"content">> => [#{<<"type">> => <<"output_text">>,
                                        <<"text">> => <<"responses-output-marker">>}]}]},
    Chat = #{<<"id">> => <<"chat-fixture">>, <<"model">> => <<"fake-zai">>,
             <<"choices">> => [#{<<"index">> => 0,
                 <<"message">> => #{<<"role">> => <<"assistant">>,
                                    <<"content">> => <<"chat-output-marker">>},
                 <<"finish_reason">> => <<"stop">>}], <<"usage">> => ChatUsage},
    {Type, Payload0} = case {Path, Stream} of
        {<<"/codex/responses">>, false} -> {"application/json", json:encode(Response)};
        {<<"/codex/responses">>, true} ->
            {"text/event-stream", sse(json:encode(#{<<"type">> => <<"response.completed">>,
                                                 <<"response">> => Response}))};
        {<<"/v1/chat/completions">>, false} -> {"application/json", json:encode(Chat)};
        {<<"/v1/chat/completions">>, true} ->
            Chunk = #{<<"id">> => <<"chat-fixture">>, <<"model">> => <<"fake-zai">>,
                      <<"choices">> => [#{<<"index">> => 0,
                          <<"delta">> => #{<<"role">> => <<"assistant">>,
                                           <<"content">> => <<"chat-output-marker">>},
                          <<"finish_reason">> => <<"stop">>}]},
            Final = #{<<"id">> => <<"chat-fixture">>, <<"model">> => <<"fake-zai">>,
                      <<"choices">> => [], <<"usage">> => ChatUsage},
            {"text/event-stream", [sse(json:encode(Chunk)),
                                    sse(json:encode(Final)), "data: [DONE]\n\n"]}
    end,
    Payload = iolist_to_binary(Payload0),
    gen_tcp:send(Socket, ["HTTP/1.1 200 OK\r\ncontent-type: ", Type,
                          "\r\ncontent-length: ", integer_to_list(byte_size(Payload)),
                          "\r\nconnection: close\r\n\r\n", Payload]),
    gen_tcp:close(Socket).

sse(Data) -> ["data: ", Data, "\n\n"].

count(#{pid := Pid}) -> Pid ! {count, self()}, receive {count, N} -> N after 1000 -> error(counter_timeout) end.
take(#{pid := Pid}) -> Pid ! {take, self()}, receive {take, R} -> R after 1000 -> error(request_timeout) end.

%% Request access is mediated through messages handled by the fixture process.
assert_request(Fixture, Path, AuthorizationPrefix, Model, Streaming) ->
    Request = take(Fixture),
    Path = maps:get(path, Request),
    Headers = maps:get(headers, Request),
    Auth = maps:get(<<"authorization">>, Headers),
    AuthorizationPrefix = Auth,
    Body = maps:get(body, Request),
    #{<<"model">> := Model, <<"stream">> := Streaming} = json:decode(Body),
    Accept = case Streaming of true -> <<"text/event-stream">>; false -> <<"application/json">> end,
    Accept = maps:get(<<"accept">>, Headers),
    case Path of
        <<"/v1/chat/completions">> ->
            case Streaming of
                true ->
                    true = binary:match(Body, <<"stream_options">>) =/= nomatch,
                    true = binary:match(Body, <<"include_usage\":true">>) =/= nomatch;
                false -> nomatch = binary:match(Body, <<"stream_options">>)
            end;
        _ -> ok
    end,
    Request.

assert_header(#{headers := Headers}, Name, Value) -> Value = maps:get(Name, Headers).
assert_not_header(#{headers := Headers}, Name) -> false = maps:is_key(Name, Headers).
assert_body_contains(#{body := Body}, Marker) -> true = binary:match(Body, Marker) =/= nomatch.

stop_upstream(#{pid := Pid, socket := Socket}) ->
    _ = try gen_tcp:close(Socket) catch _:_ -> ok end,
    _ = try exit(Pid, shutdown) catch _:_ -> ok end,
    ok.

await_started(Host, Acc) ->
    receive
        {Host, {data, {eol, Line}}} ->
            Next = <<Acc/binary, (list_to_binary(Line))/binary>>,
            case binary:match(Next, <<"subscriptions host started">>) of
                nomatch -> await_started(Host, Next);
                _ -> ok
            end;
        {Host, {data, {noeol, Chunk}}} -> await_started(Host, <<Acc/binary, (list_to_binary(Chunk))/binary>>);
        {Host, {exit_status, Status}} -> error({subscriptions_host_exited_before_ready, Status})
    after 10000 -> error(subscriptions_host_startup_timeout)
    end.

path_string(Path) when is_binary(Path) -> binary_to_list(Path);
path_string(Path) -> Path.

request(Port, Method, Path, Body, Headers) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ path_string(Path),
    H = [{"connection", "close"} | Headers],
    Result = case Method of
        get -> httpc:request(get, {Url, H}, [{timeout, 3000}], [{body_format, binary}]);
        post -> httpc:request(post, {Url, H, "application/json", Body}, [{timeout, 5000}], [{body_format, binary}])
    end,
    case Result of
        {ok, {{_, Code, _}, _, Response}} -> {Code, Response};
        {error, Reason} -> {error, Reason}
    end.

verify_startup_rejections(Erl, Args, Env, Auth) ->
    Missing = Auth ++ "-missing",
    Corrupt = Auth ++ "-corrupt",
    ok = file:write_file(Corrupt, <<"{not-json">>),
    try
        lists:foreach(fun(Path) ->
            CleanEnv = [{K, V} || {K, V} <- Env, K =/= "OPENAI_COMPAT_CODEX_TOKEN"],
            ChildEnv = [{"OPENAI_COMPAT_CODEX_TOKEN", false} |
                lists:keystore("PIG_CODEX_AUTH_PATH", 1, CleanEnv, {"PIG_CODEX_AUTH_PATH", Path})],
            Child = open_port({spawn_executable, Erl}, [{args, Args}, {env, ChildEnv}, exit_status, use_stdio, stderr_to_stdout]),
            receive
                {Child, {exit_status, 2}} -> ok;
                {Child, {exit_status, Status}} -> error({credential_startup_status, Path, Status})
            after 5000 -> error({credential_startup_timeout, Path})
            end
        end, [Missing, Corrupt])
    after
        file:delete(Corrupt)
    end.

force_cleanup_host(Host) ->
    case erlang:port_info(Host, os_pid) of
        {os_pid, Pid} ->
            os:cmd("kill -KILL " ++ integer_to_list(Pid)),
            _ = try port_close(Host) catch error:badarg -> ok end,
            ok;
        undefined -> ok
    end.

stop_host(Host, Port) ->
    case erlang:port_info(Host, os_pid) of
        {os_pid, Pid} ->
            os:cmd("kill -TERM " ++ integer_to_list(Pid)),
            receive {Host, {exit_status, 0}} ->
                        case gen_tcp:connect({127,0,0,1}, Port, [binary, {active, false}], 250) of
                            {ok, Socket} -> gen_tcp:close(Socket), error(host_listener_still_open);
                            {error, econnrefused} -> ok;
                            {error, Reason} -> error({listener_close_check, Reason})
                        end;
                    {Host, {exit_status, Status}} -> error({host_exit_status, Status})
            after 5000 ->
                os:cmd("kill -KILL " ++ integer_to_list(Pid)),
                receive {Host, {exit_status, Status}} -> error({host_shutdown_timeout, Status}) after 1000 -> error(host_orphaned) end
            end;
        undefined -> error(host_port_missing_os_pid)
    end.
