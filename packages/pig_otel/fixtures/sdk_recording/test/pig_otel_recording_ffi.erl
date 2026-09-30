-module(pig_otel_recording_ffi).
-export([with_sdk/1, snapshot/0]).
-include_lib("opentelemetry_api/include/opentelemetry.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").
-define(TABLE, pig_otel_recorded_spans).

%% The fixture, not pig_otel, owns SDK configuration/startup/shutdown.
%% Simple processor export is synchronous; snapshot needs no delay or flush.
with_sdk(Work) ->
    _ = application:stop(opentelemetry),
    Table = ets:new(?TABLE, [named_table, public, duplicate_bag]),
    Injector = opentelemetry:get_text_map_injector(),
    Extractor = opentelemetry:get_text_map_extractor(),
    application:set_env(opentelemetry, span_processor,
                        {otel_simple_processor,
                         #{exporter => {otel_exporter_tab, ?TABLE},
                           exporting_timeout_ms => 5000}}),
    application:set_env(opentelemetry, sampler, {parent_based, #{root => always_on}}),
    application:set_env(opentelemetry, create_application_tracers, false),
    application:set_env(opentelemetry, text_map_propagators, [trace_context, baggage]),
    {ok, _} = application:ensure_all_started(opentelemetry),
    try
        {otel_tracer_default, _} = otel_tracer_provider:get_tracer(
                                    pig_otel_sdk_recording, "0.1.0", undefined),
        Work()
    after
        application:stop(opentelemetry),
        ets:delete(Table),
        opentelemetry:set_text_map_injector(Injector),
        opentelemetry:set_text_map_extractor(Extractor)
    end.

snapshot() ->
    [to_snapshot(Span) || Span <- ets:tab2list(?TABLE)].

to_snapshot(#span{name=Name, kind=Kind, trace_id=TraceId, span_id=SpanId,
                  parent_span_id=ParentId, status=Status,
                  instrumentation_scope=#instrumentation_scope{name=Scope, version=Version,
                                                               schema_url=SchemaUrl},
                  attributes=Attributes}) ->
    {snapshot, Name, atom_to_binary(Kind, utf8), hex(TraceId, 32),
     hex(SpanId, 16), hex(ParentId, 16), status(Status), binary(Scope),
     binary(Version), binary(SchemaUrl),
     [{Key, value(Value)} || {Key, Value} <- maps:to_list(otel_attributes:map(Attributes))]}.

hex(undefined, _) -> <<>>;
hex(Value, 32) -> iolist_to_binary(io_lib:format("~32.16.0b", [Value]));
hex(Value, 16) -> iolist_to_binary(io_lib:format("~16.16.0b", [Value])).

status(undefined) -> <<"unset">>;
status(#status{code=Code}) -> atom_to_binary(Code, utf8).

binary(undefined) -> <<>>;
binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
binary(Value) when is_binary(Value) -> Value;
binary(Value) -> unicode:characters_to_binary(Value).

value(Value) when is_binary(Value) -> {string_value, Value};
value(Value) when is_integer(Value) -> {int_value, Value};
value(Value) when is_boolean(Value) -> {bool_value, Value};
value(Value) when is_float(Value) -> {float_value, Value};
value(Value) when is_list(Value) -> {string_list, Value}.
