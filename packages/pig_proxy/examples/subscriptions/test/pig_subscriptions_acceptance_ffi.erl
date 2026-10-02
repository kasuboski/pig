-module(pig_subscriptions_acceptance_ffi).
-export([run/0]).

run() ->
    process_flag(trap_exit, true),
    application:ensure_all_started(inets),
    Root = filename:absname("."),
    Example = filename:join([Root, "packages", "pig_proxy", "examples", "subscriptions"]),
    Erl = os:find_executable("erl"),
    Port = free_port(),
    Auth = filename:join([tmp_dir(), "pig-subscriptions-no-auth-" ++ integer_to_list(erlang:unique_integer([positive]))]),
    false = filelib:is_file(Auth),
    GleamEbins = filelib:wildcard(filename:join(Example, "build/dev/erlang/*/ebin")),
    DependencyEbens = filelib:wildcard(filename:join(Example, "host/_build/default/lib/*/ebin")),
    Paths = lists:append([ ["-pa", P] || P <- GleamEbins ++ DependencyEbens ]),
    Args = ["-noshell"] ++ Paths ++ ["-eval", "subscriptions@host:main()."],
    Env = [{"PIG_CHATGPT_MODELS", "fake-codex"},
           {"PIG_ZAI_MODELS", "fake-zai"}, {"ZAI_API_KEY", "synthetic-zai-key"},
           {"PIG_CHATGPT_BASE_URL", "http://127.0.0.1:1/v1"},
           {"PIG_ZAI_BASE_URL", "http://127.0.0.1:1/v1"},
           {"PIG_PROXY_PORT", integer_to_list(Port)},
           {"PIG_PROXY_MODELS_DEV_URL", "http://127.0.0.1:1/catalog"},
           {"PIG_CODEX_AUTH_PATH", Auth},
           {"OPENAI_COMPAT_CODEX_TOKEN", binary_to_list(fake_jwt())},
           {"PIG_LATITUDE_ENABLED", "false"}],
    Host = open_port({spawn_executable, Erl}, [{args, Args}, {env, Env}, exit_status, use_stdio, stderr_to_stdout, {line, 4096}]),
    try
        await_started(Host, <<>>),
        {200, _} = request(Port, get, "/health", <<>>, []),
        {404, _} = request(Port, get, "/not-a-route", <<>>, []),
        %% Unsupported methods and malformed/missing model requests must be rejected.
        {404, _} = request(Port, post, "/v1/unknown", <<"{}">>, []),
        {400, _} = request(Port, post, "/v1/responses", <<"{}">>, [{"content-type", "application/json"}]),
        ok
    after
        Host ! {self(), close},
        stop_host(Host),
        file:delete(Auth)
    end.

free_port() ->
    {ok, S} = gen_tcp:listen(0, [{ip, {127,0,0,1}}, {reuseaddr, true}]),
    {ok, {_, P}} = inet:sockname(S), gen_tcp:close(S), P.

tmp_dir() -> case os:getenv("TMPDIR") of false -> "/tmp"; D -> D end.

fake_jwt() ->
    Enc = fun(B) -> base64:encode(B, #{mode => urlsafe, padding => false}) end,
    <<(Enc(<<"{\"alg\":\"none\"}">>))/binary, ".",
      (Enc(<<"{\"chatgpt_account_id\":\"synthetic-account\"}">>))/binary, ".synthetic-signature">>.

await_started(Host, Acc) ->
    receive
        {Host, {data, {eol, Line}}} ->
            Next = <<Acc/binary, (list_to_binary(Line))/binary>>,
            case binary:match(Next, <<"subscriptions host started">>) of
                nomatch -> await_started(Host, Next);
                _ -> ok
            end;
        {Host, {data, {noeol, Chunk}}} ->
            await_started(Host, <<Acc/binary, (list_to_binary(Chunk))/binary>>);
        {Host, {exit_status, Status}} -> error({subscriptions_host_exited_before_ready, Status})
    after 10000 -> error(subscriptions_host_startup_timeout)
    end.

request(Port, Method, Path, Body, Headers) ->
    Url = "http://127.0.0.1:" ++ integer_to_list(Port) ++ Path,
    H = [{"connection", "close"} | Headers],
    Result = case Method of
        get -> httpc:request(get, {Url, H}, [{timeout, 3000}], [{body_format, binary}]);
        post -> httpc:request(post, {Url, H, "application/json", Body}, [{timeout, 5000}], [{body_format, binary}])
    end,
    case Result of
        {ok, {{_, Code, _}, _, Response}} -> {Code, Response};
        {error, Reason} -> {error, Reason}
    end.

stop_host(Host) ->
    %% Explicit port closure terminates the child VM even when startup failed.
    try port_close(Host) catch error:badarg -> ok end,
    receive {Host, {exit_status, _}} -> ok after 5000 -> ok end.
