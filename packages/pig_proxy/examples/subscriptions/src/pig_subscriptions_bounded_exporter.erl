%% Subscription-host adapter: cap each OTLP request without changing SDK queueing.
-module(pig_subscriptions_bounded_exporter).

-export([init/1, export/3, export/4, shutdown/1]).

-define(MAX_SPANS_PER_REQUEST, 4).

init(Options) ->
    otel_exporter_traces_otlp:init(Options).

export(SpansTid, Resource, State) ->
    export(traces, SpansTid, Resource, State).

export(traces, SpansTid, Resource, State) ->
    export_batches(ets:select(SpansTid, [{'$1', [], ['$1']}], ?MAX_SPANS_PER_REQUEST),
                   SpansTid, Resource, State);
export(_Signal, _Batch, _Resource, _State) ->
    {error, unimplemented}.

export_batches('$end_of_table', _Source, _Resource, _State) ->
    ok;
export_batches({Spans, Continuation}, Source, Resource, State) ->
    Type = ets:info(Source, type),
    KeyPosition = ets:info(Source, keypos),
    Batch = ets:new(pig_subscriptions_export_batch,
                    [Type, private, {keypos, KeyPosition}]),
    Result = try
        true = ets:insert(Batch, Spans),
        otel_exporter_traces_otlp:export(Batch, Resource, State)
    after
        ets:delete(Batch)
    end,
    case Result of
        ok -> export_batches(ets:select(Continuation), Source, Resource, State);
        Failure -> Failure
    end.

shutdown(State) ->
    otel_exporter_traces_otlp:shutdown(State).
