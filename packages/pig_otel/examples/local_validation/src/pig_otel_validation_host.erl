-module(pig_otel_validation_host).
-export([check_recording/1, check_agent_recording/1, check_proxy_recording/1,
         check_proxy_content_recording/1, check_proxy_content_otlp/1, check_proxy_content_overflow/1,
         check_content_limits/1, check_content_malformed/1, check_content_retry/1,
         check_content_unavailable/1, check_content_disabled/1,
         check_content_interrupt/1,
         check_otlp/1, check_proxy_otlp/1, check_stream_races/0, check_runtime_shutdown/0,
         check_limitations/1, check_disabled/1, check_failure/1,
         callback/1, with_caller_parent/2, integration_enabled/0,
         register_proxy_owners/1, stop_proxy_owners/0, bootstrap/0]).
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-define(TABLE, pig_otel_validation_spans).
-define(FACTS, pig_otel_validation_facts).

%% Called by the shell BEFORE generated Gleam application startup.
bootstrap() ->
    {ok, _} = application:ensure_all_started(opentelemetry_exporter),
    %% Start consumer dependency applications (including Mist's clock), not the
    %% host application whose generated dependency order would start SDK early.
    {ok, _} = application:ensure_all_started(pig),
    {ok, _} = application:ensure_all_started(pig_proxy),
    load(pig_otel_local_validation),
    nil.

register_proxy_owners(Pid) when is_pid(Pid) ->
    undefined = get(pig_otel_validation_proxy_owners),
    put(pig_otel_validation_proxy_owners, Pid),
    nil.

stop_proxy_owners() ->
    Pid = erase(pig_otel_validation_proxy_owners),
    ok = gen_server:stop(Pid, shutdown, infinity),
    nil.

integration_enabled() ->
    case os:getenv("PIG_RUN_OTEL_INTEGRATION") of
        "1" -> true;
        _ -> io:format("SKIP local OTel integration (PIG_RUN_OTEL_INTEGRATION != 1)~n"), false
    end.

check_recording(Work) ->
    record(Work, fun pig_otel_validation_verify:check/2, "recording.term").

check_agent_recording(Work) ->
    record(Work, fun pig_otel_validation_verify:check_agents/2, "agent-recording.term").

check_proxy_recording(Work) ->
    record(Work, fun pig_otel_validation_verify:check_proxy_sync/2, "proxy-sync-recording.term").

check_proxy_content_recording(Work) ->
    record(Work, fun pig_otel_validation_verify:check_proxy_content/2, "proxy-content-recording.term").

check_proxy_content_otlp(Work) ->
    deliver(Work, fun pig_otel_validation_verify:check_proxy_content/2, 12, "proxy-content-otlp.term").

check_content_interrupt(Work) ->
    record(Work, fun pig_otel_validation_verify:check_proxy_content_interrupt/2,
           "proxy-content-interrupt-recording.term").

check_content_malformed(Work) ->
    record(Work, fun pig_otel_validation_verify:check_proxy_content_malformed/2,
           "proxy-content-malformed-recording.term"),
    deliver(Work, fun pig_otel_validation_verify:check_proxy_content_malformed/2,
            6, "proxy-content-malformed-otlp.term").

check_content_retry(Work) ->
    record(Work, fun pig_otel_validation_verify:check_proxy_content_retry/2,
           "proxy-content-retry-recording.term"),
    deliver(Work, fun pig_otel_validation_verify:check_proxy_content_retry/2,
            16, "proxy-content-retry-otlp.term").

check_content_unavailable(Work) ->
    lists:foreach(fun(Mode) ->
        prepare(Mode),
        try
            case Mode of
                no_sdk -> ok;
                unsampled -> start_sdk({otel_simple_processor,
                    #{exporter => {otel_exporter_tab, ?TABLE}}}, always_off)
            end,
            Work(),
            [] = ets:tab2list(?TABLE),
            io:format("PASS capture configured ~p: business unchanged, zero exported spans~n", [Mode])
        after cleanup() end
    end, [no_sdk, unsampled]),
    nil.

check_content_disabled(Work) -> check_disabled(Work).

check_proxy_content_overflow(Work) ->
    record(Work, fun pig_otel_validation_verify:check_proxy_content_overflow/2,
           "proxy-content-overflow-recording.term").

check_content_limits(Work) ->
    prepare(limited),
    try
        application:set_env(opentelemetry, attribute_value_length_limit, 48),
        start_sdk({otel_simple_processor, #{exporter => {otel_exporter_tab, ?TABLE}}}, always_on),
        Work(),
        Logical = [recorded(S) || S=#span{kind=client} <- ets:tab2list(?TABLE),
                                  maps:is_key(<<"openai.api.type">>, otel_attributes:map(S#span.attributes))],
        4 = length(Logical),
        lists:foreach(fun(Span) ->
            Attrs = maps:get(attributes, Span),
            Value = maps:get(<<"gen_ai.input.messages">>, Attrs),
            48 = byte_size(Value),
            invalid_json_after_limit(Value)
        end, Logical),
        io:format("PASS official SDK limit truncates content JSON; invalid JSON is not a capture success~n")
    after cleanup(), application:unset_env(opentelemetry, attribute_value_length_limit) end,
    nil.

check_stream_races() ->
    prepare(recording),
    try
        start_sdk({otel_simple_processor,
                   #{exporter => {otel_exporter_tab, ?TABLE}}}, always_on),
        Results = [record_race(Api, Boundary, Expected, Usage,
                              fun() -> 'support@tracing_death_harness':check_death(Api, Boundary) end)
                   || Api <- [chat_completions, responses],
                      {Boundary, Expected, Usage} <- race_cases()],
        %% The unchanged proxy fixture contains 9/3 and no cache count.
        %% Independently exercise 7/3/2 via a host-local real source callback.
        Extra = [record_race(Api, eof_usage_7_3_2,
                             {cancelled, <<"client_disconnected">>}, host_eof,
                             fun() -> pig_otel_validation_eof_race:check(Api) end)
                 || Api <- [chat_completions, responses]],
        ManagedStops = [record_race(Api, {runtime_stop, Ownership},
                                   {cancelled, <<"agent_stopped">>}, absent,
                                   fun() -> 'support@runtime_harness':check_stop(Api, Ownership) end)
                        || Api <- [chat_completions, responses],
                           Ownership <- [managed, external]],
        ets:delete_all_objects(?TABLE),
        'support@tracing_death_harness':check_dormant_registration(),
        [] = ets:tab2list(?TABLE),
        All = Results ++ Extra ++ ManagedStops,
        Spans = lists:flatmap(fun(#{spans := S}) -> S end, All),
        72 = length(Spans),
        true = pig_otel_validation_verify:unique_ids(Spans),
        24 = length(lists:usort([maps:get(trace_id, hd(S)) || #{spans := S} <- All])),
        write_evidence("official-races-recording.term", All),
        write_evidence("official-dormant-recording.term", []),
        io:format("PASS official SDK streaming race matrix: 54 actual spans / 18 cases; "
                  "6 additional EOF usage spans / 2 cases; 12 runtime stop spans / 4 cases; "
                  "dormant registration zero spans~n")
    after cleanup() end,
    nil.

check_runtime_shutdown() ->
    Work = fun() ->
        lists:foreach(fun(Api) -> 'support@runtime_harness':check_stop(Api, managed) end,
                      [chat_completions, responses]),
        nil
    end,
    Verify = fun(Spans, _Facts) ->
        6 = length(Spans),
        lists:foreach(fun(Api) ->
            ApiName = atom_to_binary(Api, utf8),
            [Logical] = [S || S=#{attributes := A} <- Spans,
                             maps:get(<<"openai.api.type">>, A, undefined) =:= ApiName],
            Trace = maps:get(trace_id, Logical),
            Group = [S || S <- Spans, maps:get(trace_id, S) =:= Trace],
            ok = verify_race_group(Api, Group, {cancelled, <<"agent_stopped">>}, absent)
        end, [chat_completions, responses]),
        true = pig_otel_validation_verify:unique_ids(Spans),
        ok
    end,
    record(Work, Verify, "runtime-shutdown-recording.term"),
    deliver(Work, Verify, 6, "runtime-shutdown-otlp.term").

race_cases() ->
    [{before_init, {cancelled, <<"client_disconnected">>}, absent},
     {during_handoff, {cancelled, <<"client_disconnected">>}, absent},
     {upstream_finished_before_handoff, {cancelled, <<"client_disconnected">>}, proxy_eof},
     {after_acknowledgement, {cancelled, <<"client_disconnected">>}, absent},
     {chunk_exception, {failed, <<"callback_error">>}, absent},
     {send_failure, {failed, <<"downstream_error">>}, absent},
     {cancellation, {cancelled, <<"cancelled">>}, absent},
     {shutdown, {cancelled, <<"agent_stopped">>}, absent},
     {supervisor_shutdown, {cancelled, <<"agent_stopped">>}, absent}].

record_race(Api, Boundary, Expected, Usage, Work) ->
    ets:delete_all_objects(?TABLE),
    otel_ctx:clear(),
    Work(),
    %% Owner retirement and synchronous simple-exporter inserts are the barrier.
    Spans = [recorded(S) || S <- ets:tab2list(?TABLE)],
    Label = case Boundary of
        {runtime_stop, Ownership} -> "runtime_stop-" ++ atom_to_list(Ownership);
        _ -> atom_to_list(Boundary)
    end,
    write_evidence(atom_to_list(Api) ++ "-" ++ Label ++ ".term", Spans),
    ok = verify_race_group(Api, Spans, Expected, Usage),
    io:format("PASS official SDK race ~p/~p: exactly 3 unique ends~n", [Api, Boundary]),
    #{api => Api, boundary => Boundary, expected => Expected, usage => Usage, spans => Spans}.

verify_race_group(Api, Group, Expected, Usage) ->
    3 = length(Group),
    true = pig_otel_validation_verify:unique_ids(Group),
    true = pig_otel_validation_verify:safe_metadata(Group),
    [Server] = [S || S=#{kind := server} <- Group],
    [Logical] = [S || S=#{kind := client, attributes := A} <- Group,
                       maps:get(<<"gen_ai.operation.name">>, A, undefined) =:= <<"chat">>],
    [Attempt] = [S || S=#{kind := client, attributes := A} <- Group,
                       maps:is_key(<<"pig.proxy.target.id">>, A)],
    lists:foreach(fun verify_race_span/1, Group),
    <<>> = maps:get(parent_span_id, Server),
    true = pig_otel_validation_verify:related(Server, Logical),
    true = pig_otel_validation_verify:related(Logical, Attempt),
    Route = case Api of responses -> <<"/v1/responses">>; _ -> <<"/v1/chat/completions">> end,
    ApiName = atom_to_binary(Api, utf8),
    Route = attr(<<"http.route">>, Server),
    ApiName = attr(<<"openai.api.type">>, Logical),
    ServerName = <<"POST ", Route/binary>>,
    ServerName = maps:get(name, Server),
    <<"chat fixture_model">> = maps:get(name, Logical),
    <<"POST">> = maps:get(name, Attempt),
    200 = attr(<<"http.response.status_code">>, Server),
    200 = attr(<<"http.response.status_code">>, Attempt),
    <<"primary">> = attr(<<"pig.proxy.target.id">>, Attempt),
    1 = attr(<<"pig.proxy.attempt">>, Attempt),
    verify_terminal(Server, Expected),
    Upstream = case Usage of absent -> Expected; _ -> succeeded end,
    verify_terminal(Logical, Upstream),
    verify_terminal(Attempt, Upstream),
    verify_usage(Logical, Api, Usage),
    lists:foreach(fun(S) -> verify_usage(S, Api, absent) end, [Server, Attempt]),
    ok.

verify_race_span(#{scope := Scope, version := Version, schema := Schema,
                   trace_id := Trace, span_id := Id, start := Start, 'end' := End,
                   events := Events, links := Links, attributes := Attrs}) ->
    <<"pig_proxy">> = Scope,
    <<"0.2.0">> = Version,
    <<>> = Schema,
    32 = byte_size(Trace),
    16 = byte_size(Id),
    true = Start > 0 andalso End >= Start,
    [] = Events,
    [] = Links,
    Forbidden = [<<"gen_ai.input.messages">>, <<"gen_ai.output.messages">>,
                 <<"gen_ai.system_instructions">>, <<"gen_ai.tool.call.arguments">>,
                 <<"gen_ai.tool.call.result">>, <<"exception.message">>,
                 <<"exception.stacktrace">>, <<"url.full">>, <<"baggage">>],
    [] = [K || K <- Forbidden, maps:is_key(K, Attrs)].

verify_terminal(Span, succeeded) ->
    unset = maps:get(status, Span),
    <<"succeeded">> = attr(<<"pig.outcome">>, Span),
    false = maps:is_key(<<"error.type">>, maps:get(attributes, Span));
verify_terminal(Span, {Outcome, Category}) ->
    error = maps:get(status, Span),
    Name = atom_to_binary(Outcome, utf8),
    Name = attr(<<"pig.outcome">>, Span),
    Category = attr(<<"error.type">>, Span).

verify_usage(Span, Api, Usage) ->
    Keys = [<<"gen_ai.usage.input_tokens">>, <<"gen_ai.usage.output_tokens">>,
            <<"gen_ai.usage.cache_read.input_tokens">>, <<"gen_ai.response.id">>,
            <<"gen_ai.response.model">>, <<"gen_ai.response.finish_reasons">>],
    Present = maps:with(Keys, maps:get(attributes, Span)),
    Expected = case Usage of
        absent -> #{};
        proxy_eof ->
            Base = #{<<"gen_ai.usage.input_tokens">> => 9,
                     <<"gen_ai.usage.output_tokens">> => 3},
            case Api of
                responses -> Base#{<<"gen_ai.response.id">> => <<"r">>,
                                   <<"gen_ai.response.model">> => <<"m">>,
                                   <<"gen_ai.response.finish_reasons">> => [<<"stop">>]};
                _ -> Base
            end;
        host_eof -> #{<<"gen_ai.usage.input_tokens">> => 7,
                      <<"gen_ai.usage.output_tokens">> => 3,
                      <<"gen_ai.usage.cache_read.input_tokens">> => 2,
                      <<"gen_ai.response.id">> => <<"r">>,
                      <<"gen_ai.response.model">> => <<"m">>,
                      <<"gen_ai.response.finish_reasons">> => [<<"stop">>]}
    end,
    Expected = Present,
    ok.

attr(Key, Span) -> maps:get(Key, maps:get(attributes, Span)).

invalid_json_after_limit(Value) ->
    try json:decode(Value) of
        {error, _} -> ok;
        _ -> throw(valid_json_after_limit)
    catch
        throw:valid_json_after_limit -> error(valid_json_after_limit);
        _:_ -> ok
    end.

record(Work, Verify, File) ->
    prepare(recording),
    try
        start_sdk({otel_simple_processor,
                   #{exporter => {otel_exporter_tab, ?TABLE}}}, always_on),
        Work(),
        Spans = [recorded(S) || S <- ets:tab2list(?TABLE)],
        write_evidence(File, Spans),
        Verify(Spans, ets:tab2list(?FACTS)),
        io:format("PASS official SDK recording (~s): ~p actual consumer spans~n", [File, length(Spans)])
    after cleanup() end,
    nil.

check_otlp(Work) ->
    deliver(Work, fun pig_otel_validation_verify:check/2, 20, "otlp.term").

check_proxy_otlp(Work) ->
    deliver(Work, fun pig_otel_validation_verify:check_proxy_sync/2, 6, "proxy-sync-otlp.term").

deliver(Work, Verify, Expected, File) ->
    prepare(otlp),
    Receiver = pig_otel_validation_receiver:start(File),
    try
        Endpoint = pig_otel_validation_receiver:endpoint(Receiver),
        application:set_env(opentelemetry_exporter, otlp_endpoint, Endpoint),
        application:set_env(opentelemetry_exporter, otlp_protocol, http_protobuf),
        start_sdk({otel_batch_processor, #{scheduled_delay_ms => 60000}}, always_on),
        Work(),
        ok = otel_tracer_provider:force_flush(),
        %% force_flush is a cast, not delivery evidence. Receiver verifies the
        %% complete decoded span set and ACKs before host shutdown.
        Spans = pig_otel_validation_receiver:snapshot(Receiver, Expected),
        write_evidence(File, Spans),
        Verify(Spans, ets:tab2list(?FACTS)),
        io:format("PASS OTLP receiver ACK: ~p actual consumer spans~n", [length(Spans)])
    after
        cleanup(),
        pig_otel_validation_receiver:stop(Receiver)
    end,
    nil.

check_failure(Work) ->
    record(Work, fun pig_otel_validation_verify:check_failure/2, "failure-recording.term"),
    deliver(Work, fun pig_otel_validation_verify:check_failure/2, 2, "failure-otlp.term").

check_disabled(Work) ->
    prepare(disabled),
    try
        start_sdk({otel_simple_processor,
                   #{exporter => {otel_exporter_tab, ?TABLE}}}, always_on),
        Work(),
        [] = ets:tab2list(?TABLE),
        io:format("PASS Disabled policy: unchanged business, zero exported Pig spans~n")
    after cleanup() end,
    nil.

check_limitations(Work) ->
    lists:foreach(fun(Mode) ->
        prepare(Mode),
        try
            case Mode of
                no_sdk -> ok;
                unsampled -> start_sdk({otel_simple_processor,
                                #{exporter => {otel_exporter_tab, ?TABLE}}}, always_off);
                outage ->
                    %% Reserve, then close a loopback endpoint: no external IO.
                    {ok, L} = gen_tcp:listen(0, [{ip, {127,0,0,1}}]),
                    {ok, {_, Port}} = inet:sockname(L),
                    ok = gen_tcp:close(L),
                    application:set_env(opentelemetry_exporter, otlp_endpoint,
                                        "http://127.0.0.1:" ++ integer_to_list(Port)),
                    application:set_env(opentelemetry_exporter, otlp_protocol, http_protobuf),
                    start_sdk({otel_simple_processor, #{}}, always_on)
            end,
            Work(),
            [] = ets:tab2list(?TABLE),
            io:format("PASS business output unchanged: ~p (not delivery evidence)~n", [Mode])
        after cleanup() end
    end, [no_sdk, unsampled, outage]),
    nil.

prepare(Mode) ->
    bootstrap(),
    stop_sdk(),
    new_table(?TABLE, duplicate_bag),
    new_table(?FACTS, bag),
    ets:insert(?FACTS, {mode, Mode}),
    otel_ctx:clear(),
    application:set_env(opentelemetry, resource,
                        #{<<"service.name">> => <<"pig-otel-local-validation">>}),
    application:set_env(opentelemetry, text_map_propagators, [trace_context, baggage]),
    %% API-only hosts still configure propagation explicitly; starting an SDK
    %% is not required to extract/inject the supported composite carrier.
    opentelemetry:set_text_map_propagator(
        otel_propagator_text_map_composite:create([trace_context, baggage])),
    nil.

start_sdk(Processor, Sampler) ->
    application:set_env(opentelemetry, span_processor, Processor),
    application:set_env(opentelemetry, sampler, Sampler),
    {ok, _} = application:ensure_all_started(opentelemetry),
    %% Marker identity is consumer-owned. Do not supply a fixture marker or
    %% manufacture application tracer identities on behalf of the consumers.
    opentelemetry:set_text_map_propagator(
        otel_propagator_text_map_composite:create([trace_context, baggage])),
    ok.

with_caller_parent(Streaming, Work) ->
    Index = case Streaming of false -> 101; true -> 102 end,
    Trace = hex(Index, 32),
    Parent = <<"2222222222222222">>,
    Carrier = [{<<"traceparent">>, <<"00-", Trace/binary, "-", Parent/binary, "-01">>}],
    Before = otel_ctx:get_current(),
    Ctx = otel_propagator_text_map:extract_to(#{}, Carrier),
    {nil, _} = otel_ctx:with_ctx(Ctx, Work),
    Before = otel_ctx:get_current(),
    ets:insert(?FACTS, {caller, Trace, Parent}),
    nil.

callback(Label) ->
    #span_ctx{trace_id=Trace, span_id=Span, is_valid=Valid} = otel_tracer:current_span_ctx(),
    [{mode, Mode}] = ets:lookup(?FACTS, mode),
    case Mode of no_sdk -> ok; disabled -> ok; _ -> true = Valid end,
    ets:insert(?FACTS, {callback, Label, hex(Trace, 32), hex(Span, 16)}),
    nil.

recorded(#span{trace_id=Trace, span_id=Id, parent_span_id=Parent,
               name=Name, kind=Kind, status=Status, attributes=Attrs,
               start_time=Start, end_time=End, instrumentation_scope=Scope,
               events=Events, links=Links}) ->
    #instrumentation_scope{name=ScopeName, version=Version, schema_url=Schema} = Scope,
    #{trace_id => hex(Trace, 32), span_id => hex(Id, 16),
      parent_span_id => hex(Parent, 16), name => Name, kind => Kind,
      status => status(Status), attributes => otel_attributes:map(Attrs),
      start => opentelemetry:timestamp_to_nano(Start),
      'end' => opentelemetry:timestamp_to_nano(End),
      scope => text(ScopeName), version => unicode:characters_to_binary(Version),
      schema => text(Schema), events => otel_events:list(Events), links => otel_links:list(Links)}.

status(undefined) -> unset;
status(#status{code=Code, message=Message}) ->
    true = Message =:= undefined orelse Message =:= <<>>,
    case Code of unset -> unset; ok -> ok; error -> error end.

hex(undefined, _) -> <<>>;
hex(0, _) -> <<>>;
hex(Id, Width) -> iolist_to_binary(io_lib:format("~*.16.0b", [Width, Id])).
text(undefined) -> <<>>;
text(V) -> unicode:characters_to_binary(V).

cleanup() ->
    stop_sdk(),
    otel_ctx:clear(),
    ets:delete(?TABLE),
    ets:delete(?FACTS),
    nil.
stop_sdk() ->
    case application:stop(opentelemetry) of
        ok -> ok;
        {error, {not_started, opentelemetry}} -> ok
    end.
load(App) ->
    case application:load(App) of ok -> ok; {error, {already_loaded, App}} -> ok end.
new_table(Name, Type) ->
    case ets:whereis(Name) of undefined -> ok; _ -> ets:delete(Name) end,
    ets:new(Name, [named_table, public, Type]).
write_evidence(File, Term) ->
    case os:getenv("PIG_OTEL_EVIDENCE_DIR") of
        false -> ok;
        Dir ->
            Path = filename:join(Dir, File),
            ok = filelib:ensure_dir(Path),
            ok = file:write_file(Path, io_lib:format("~tp.~n", [Term]))
    end.
