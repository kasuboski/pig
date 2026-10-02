-module(pig_subscriptions_host_ffi).
-export([bootstrap/0, configure_latitude/3,
         await_shutdown/0, shutdown/1, halt/1,
         init/1, handle_event/2, handle_call/2, handle_info/2,
         terminate/2, code_change/3]).

bootstrap() ->
    {ok, _} = application:ensure_all_started(opentelemetry_exporter),
    {ok, _} = application:ensure_all_started(pig_proxy),
    opentelemetry:set_text_map_propagator(
        otel_propagator_text_map_composite:create([trace_context, baggage])),
    %% Replace the default handler: its init:stop races ordered host cleanup.
    ok = gen_event:delete_handler(erl_signal_server, erl_signal_handler, []),
    ok = gen_event:add_handler(erl_signal_server, ?MODULE, self()),
    ok = os:set_signal(sigterm, handle),
    nil.

configure_latitude(Endpoint, Key, Project) ->
    application:set_env(opentelemetry_exporter, otlp_endpoint, Endpoint),
    application:set_env(opentelemetry_exporter, otlp_protocol, http_protobuf),
    application:set_env(opentelemetry_exporter, otlp_compression, undefined),
    application:set_env(opentelemetry_exporter, otlp_headers,
        [{"Authorization", <<"Bearer ", Key/binary>>}, {"X-Latitude-Project", Project}]),
    application:set_env(opentelemetry, resource,
        #{<<"service.name">> => <<"pig-proxy-subscriptions">>}),
    application:set_env(opentelemetry, text_map_propagators, [trace_context, baggage]),
    {ok, _} = application:ensure_all_started(opentelemetry),
    nil.

await_shutdown() ->
    receive shutdown -> nil end.

init(Owner) -> {ok, Owner}.
handle_event(sigterm, Owner) -> Owner ! shutdown, {ok, Owner};
handle_event(_Signal, Owner) -> {ok, Owner}.
handle_call(_Request, Owner) -> {ok, ok, Owner}.
handle_info(_Info, Owner) -> {ok, Owner}.
terminate(_Reason, _Owner) -> ok.
code_change(_OldVersion, Owner, _Extra) -> {ok, Owner}.

shutdown(Cleanup) ->
    Owner = self(),
    Watchdog = spawn(fun() ->
        Monitor = erlang:monitor(process, Owner),
        receive
            complete -> erlang:demonitor(Monitor, [flush]);
            {'DOWN', Monitor, process, Owner, _} -> ok
        after 30000 ->
            io:format(standard_error, "subscriptions host shutdown timed out; trace delivery is not guaranteed~n", []),
            erlang:halt(1)
        end
    end),
    try
        Cleanup(),
        flush_sdk(),
        stop_sdk(),
        Watchdog ! complete,
        nil
    catch _:_ ->
        %% Never dump a captured settings record or callback stack with credentials.
        io:format(standard_error, "subscriptions host shutdown failed; trace delivery is not guaranteed~n", []),
        erlang:halt(1)
    end.

flush_sdk() ->
    case lists:keymember(opentelemetry, 1, application:which_applications()) of
        true -> _ = otel_tracer_provider:force_flush(), ok;
        false -> ok
    end.

halt(Status) -> erlang:halt(Status).

stop_sdk() ->
    Parent = self(),
    Ref = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Parent ! {Ref, stop_sdk_application()}
    end),
    receive
        {Ref, _Result} -> erlang:demonitor(Monitor, [flush]), ok;
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 15000 ->
        exit(Pid, kill),
        erlang:demonitor(Monitor, [flush]),
        io:format(standard_error, "subscriptions host SDK shutdown timed out; trace delivery is not guaranteed~n", []),
        erlang:halt(1)
    end.

stop_sdk_application() ->
    case application:stop(opentelemetry) of
        ok -> ok;
        {error, {not_started, opentelemetry}} -> ok
    end.
