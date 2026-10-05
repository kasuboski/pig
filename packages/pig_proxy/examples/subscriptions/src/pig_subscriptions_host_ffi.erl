%% Only SDK/application interop and the Erlang OS-signal behaviour live here.
-module(pig_subscriptions_host_ffi).
-behaviour(gen_event).
-export([bootstrap/0, configure_latitude/3, install_signals/1, stop_sdk/0,
         init/1, handle_event/2, handle_call/2]).

bootstrap() ->
    {ok, _} = application:ensure_all_started(opentelemetry_exporter),
    {ok, _} = application:ensure_all_started(pig_proxy),
    opentelemetry:set_text_map_propagator(
        otel_propagator_text_map_composite:create([trace_context, baggage])),
    nil.

configure_latitude(Endpoint, Key, Project) ->
    %% This signal-specific URL must not gain another /v1/traces suffix.
    application:set_env(opentelemetry_exporter, otlp_traces_endpoint, Endpoint),
    application:set_env(opentelemetry_exporter, otlp_protocol, http_protobuf),
    application:set_env(opentelemetry_exporter, otlp_compression, undefined),
    application:set_env(opentelemetry_exporter, otlp_headers,
        [{"Authorization", <<"Bearer ", Key/binary>>}, {"X-Latitude-Project", Project}]),
    application:set_env(opentelemetry, resource,
        #{<<"service.name">> => <<"pig-proxy-subscriptions">>}),
    application:set_env(opentelemetry, text_map_propagators, [trace_context, baggage]),
    {ok, _} = application:ensure_all_started(opentelemetry),
    nil.

install_signals(Notify) ->
    %% The default SIGTERM handler would race the owner's ordered cleanup.
    ok = gen_event:delete_handler(erl_signal_server, erl_signal_handler, []),
    ok = gen_event:add_handler(erl_signal_server, ?MODULE, Notify),
    ok = os:set_signal(sigterm, handle),
    nil.

init(Notify) -> {ok, Notify}.
handle_event(sigterm, Notify) -> Notify(), {ok, Notify};
handle_event(_Signal, Notify) -> {ok, Notify}.
handle_call(_Request, Notify) -> {ok, ok, Notify}.

stop_sdk() ->
    case application:stop(opentelemetry) of
        ok -> {ok, nil};
        {error, {not_started, opentelemetry}} -> {ok, nil};
        {error, _} -> {error, nil}
    end.
