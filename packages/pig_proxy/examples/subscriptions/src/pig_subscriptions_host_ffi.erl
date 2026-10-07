%% Only SDK/application interop and the Erlang OS-signal behaviour live here.
-module(pig_subscriptions_host_ffi).
-behaviour(gen_event).
-export([bootstrap/0, configure_otlp_exporter/0, configure_bounded_otlp_exporter/0,
         install_signals/1, stop_sdk/0,
         init/1, handle_event/2, handle_call/2]).

bootstrap() ->
    {ok, _} = application:ensure_all_started(opentelemetry_exporter),
    {ok, _} = application:ensure_all_started(pig_proxy),
    opentelemetry:set_text_map_propagator(
        otel_propagator_text_map_composite:create([trace_context, otel_gleam_propagator_baggage])),
    nil.

configure_otlp_exporter() ->
    configure_bounded_otlp_exporter(),
    application:set_env(opentelemetry, resource,
        #{<<"service.name">> => <<"pig-proxy-subscriptions">>}),
    application:set_env(opentelemetry, text_map_propagators,
                         [trace_context, otel_gleam_propagator_baggage]),
    {ok, _} = application:ensure_all_started(opentelemetry),
    nil.

configure_bounded_otlp_exporter() ->
    Effective = otel_configuration:merge_with_os(application:get_all_env(opentelemetry)),
    EffectiveExporter = maps:get(traces_exporter, Effective),
    GlobalExporter = configured_global_exporter(EffectiveExporter),
    case application:get_env(opentelemetry, span_processor) of
        {ok, Processor} ->
            application:set_env(opentelemetry, span_processor,
                                rewrite_processor(Processor, GlobalExporter));
        undefined ->
            case application:get_env(opentelemetry, processors) of
                {ok, Processors} ->
                    application:set_env(opentelemetry, processors,
                        [rewrite_processor(P, GlobalExporter) || P <- Processors]);
                undefined ->
                    application:set_env(opentelemetry, span_processor,
                        rewrite_processor({otel_batch_processor, #{}}, GlobalExporter))
            end
    end,
    %% Resolve OS configuration before wrapping: OS settings otherwise win over
    %% application env again when the SDK merges its configuration at startup.
    %% Remove only this exporter selector after resolving it, then install the
    %% effective exporter in application env. All other OTEL_* settings remain.
    case GlobalExporter of
        {ok, Exporter} ->
            case is_bounded_exporter(Exporter) of
                true ->
                    os:unsetenv("OTEL_TRACES_EXPORTER"),
                    application:set_env(opentelemetry, traces_exporter,
                                        rewrite_exporter(Exporter));
                false -> ok
            end;
        undefined -> ok
    end.

configured_global_exporter(EffectiveExporter) ->
    case {application:get_env(opentelemetry, traces_exporter),
          os:getenv("OTEL_TRACES_EXPORTER")} of
        {{ok, _}, _} -> {ok, EffectiveExporter};
        {undefined, false} -> undefined;
        {undefined, _} -> {ok, EffectiveExporter}
    end.

rewrite_processor(batch, GlobalExporter) ->
    rewrite_processor({otel_batch_processor, #{}}, GlobalExporter);
rewrite_processor(simple, GlobalExporter) ->
    rewrite_processor({otel_simple_processor, #{}}, GlobalExporter);
rewrite_processor({Name, Options} = Processor, GlobalExporter)
  when (Name =:= otel_batch_processor orelse Name =:= otel_simple_processor),
       is_map(Options) ->
    EffectiveExporter = case GlobalExporter of
        {ok, Exporter} -> Exporter;
        undefined -> maps:get(exporter, Options, {opentelemetry_exporter, #{}})
    end,
    case is_bounded_exporter(EffectiveExporter) of
        false -> Processor;
        true ->
            Updated = Options#{exporting_timeout_ms =>
                                   max(300000, maps:get(exporting_timeout_ms, Options, 0))},
            {Name, rewrite_processor_exporter(Updated)}
    end;
rewrite_processor(Processor, _GlobalExporter) ->
    Processor.

is_bounded_exporter({opentelemetry_exporter, _}) -> true;
is_bounded_exporter({pig_subscriptions_bounded_otlp_exporter, _}) -> true;
is_bounded_exporter(_) -> false.

rewrite_processor_exporter(Options) ->
    case maps:get(exporter, Options, {opentelemetry_exporter, #{}}) of
        {opentelemetry_exporter, ExporterOptions} ->
            Options#{exporter => {pig_subscriptions_bounded_otlp_exporter, ExporterOptions}};
        _ -> Options
    end.

rewrite_exporter({opentelemetry_exporter, Options}) ->
    {pig_subscriptions_bounded_otlp_exporter, Options};
rewrite_exporter(Exporter) ->
    Exporter.

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
