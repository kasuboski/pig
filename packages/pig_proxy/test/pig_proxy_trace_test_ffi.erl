-module(pig_proxy_trace_test_ffi).
-export([with_calls/1, calls/1, await_finishes/2, wait_closed/2, with_composite/1]).

%% Observe shared adapter calls, not a substitute SDK/binding. Official exported
%% hierarchy/attributes are exercised separately by the host integration suite.
with_calls(Work) ->
    {module, pig_otel} = code:ensure_loaded(pig_otel),
    Parent = self(),
    Recorder = spawn_link(fun() -> record(Parent, [], #{}) end),
    erlang:trace_pattern({pig_otel, start, 3}, [{'_', [], [{return_trace}]}], [local]),
    erlang:trace_pattern({pig_otel, finish, 2}, true, [local]),
    erlang:trace(all, true, [call, set_on_spawn, {tracer, Recorder}]),
    try Work(Recorder)
    after
        erlang:trace(all, false, [call, set_on_spawn]),
        erlang:trace_pattern({pig_otel, start, 3}, false, [local]),
        erlang:trace_pattern({pig_otel, finish, 2}, false, [local]),
        Recorder ! stop
    end.

calls(Recorder) ->
    Ref = make_ref(),
    Recorder ! {snapshot, self(), Ref},
    receive {Ref, Calls} -> Calls after 5000 -> erlang:error(recording_timeout) end.

await_finishes(Recorder, Count) ->
    Ref = make_ref(),
    Recorder ! {await_finishes, self(), Ref, Count},
    receive {Ref, acknowledged} -> nil
    after 5000 -> erlang:error(upstream_finalization_ack_timeout)
    end.

finished_count(Calls) -> length([ok || {finished, _, _} <- Calls]).

await_record(Parent, Calls, Pending, Requester, Ref, Count) ->
    case finished_count(Calls) >= Count of
        true ->
            Requester ! {Ref, acknowledged},
            record(Parent, Calls, Pending);
        false ->
            receive
                {trace, Pid, call, {pig_otel, start, [_, Context, Operation]}} ->
                    await_record(Parent, Calls, Pending#{Pid => {Context, Operation}}, Requester, Ref, Count);
                {trace, Pid, return_from, {pig_otel, start, 3}, Span} ->
                    {Context, Operation} = maps:get(Pid, Pending),
                    await_record(Parent, [{started, Span, Context, Operation} | Calls], maps:remove(Pid, Pending), Requester, Ref, Count);
                {trace, _, call, {pig_otel, finish, [Span, Outcome]}} ->
                    await_record(Parent, [{finished, Span, Outcome} | Calls], Pending, Requester, Ref, Count);
                _ -> await_record(Parent, Calls, Pending, Requester, Ref, Count)
            end
    end.

record(Parent, Calls, Pending) ->
    receive
        {trace, Pid, call, {pig_otel, start, [_, ParentContext, Operation]}} ->
            record(Parent, Calls, Pending#{Pid => {ParentContext, Operation}});
        {trace, Pid, return_from, {pig_otel, start, 3}, Span} ->
            {Context, Operation} = maps:get(Pid, Pending),
            record(Parent, [{started, Span, Context, Operation} | Calls], maps:remove(Pid, Pending));
        {trace, _, call, {pig_otel, finish, [Span, Outcome]}} ->
            record(Parent, [{finished, Span, Outcome} | Calls], Pending);
        {await_finishes, Requester, Ref, Count} ->
            await_record(Parent, Calls, Pending, Requester, Ref, Count);
        {snapshot, Requester, Ref} ->
            Barrier = erlang:trace_delivered(all),
            drain(Parent, Calls, Pending, Barrier, Requester, Ref);
        stop -> ok;
        _ -> record(Parent, Calls, Pending)
    end.

drain(Parent, Calls, Pending, Barrier, Requester, Ref) ->
    receive
        {trace, Pid, call, {pig_otel, start, [_, Context, Operation]}} ->
            drain(Parent, Calls, Pending#{Pid => {Context, Operation}}, Barrier, Requester, Ref);
        {trace, Pid, return_from, {pig_otel, start, 3}, Span} ->
            {Context, Operation} = maps:get(Pid, Pending),
            drain(Parent, [{started, Span, Context, Operation} | Calls], maps:remove(Pid, Pending), Barrier, Requester, Ref);
        {trace, _, call, {pig_otel, finish, [Span, Outcome]}} ->
            drain(Parent, [{finished, Span, Outcome} | Calls], Pending, Barrier, Requester, Ref);
        {trace_delivered, all, Barrier} ->
            Requester ! {Ref, lists:reverse(Calls)},
            record(Parent, Calls, Pending);
        _ -> drain(Parent, Calls, Pending, Barrier, Requester, Ref)
    end.

wait_closed(Owner, Action) ->
    Monitor = erlang:monitor(process, Owner),
    Action(),
    receive {'DOWN', Monitor, process, Owner, _} -> nil
    after 5000 -> erlang:error(owner_cleanup_timeout)
    end.

with_composite(Work) ->
    Injector = opentelemetry:get_text_map_injector(),
    Extractor = opentelemetry:get_text_map_extractor(),
    opentelemetry:set_text_map_propagator(otel_propagator_text_map_composite:create([trace_context, baggage])),
    try Work()
    after
        opentelemetry:set_text_map_injector(Injector),
        opentelemetry:set_text_map_extractor(Extractor)
    end.
