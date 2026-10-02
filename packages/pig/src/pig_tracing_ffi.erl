-module(pig_tracing_ffi).
-export([register/1, unregister/1, protect/2]).

%% Only the runtime actor owns this registry. It also covers handles created
%% during a transition, before the next immutable actor state is returned.
register(Span) ->
    put(pig_owned_spans, [Span | spans()]),
    nil.

unregister(Span) ->
    put(pig_owned_spans, lists:delete(Span, spans())),
    nil.

spans() ->
    case get(pig_owned_spans) of undefined -> []; Spans -> Spans end.

protect(Work, Cleanup) ->
    try Work()
    catch Class:Reason:Stack ->
        Spans = spans(),
        erase(pig_owned_spans),
        lists:foreach(fun(Span) ->
            try Cleanup(Span) catch _:_ -> ok end
        end, Spans),
        erlang:raise(Class, Reason, Stack)
    end.
