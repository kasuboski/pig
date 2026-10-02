-module(pig_proxy_content_lifecycle_ffi).
-export([with_inference_annotations/1]).

%% Observe attributes passed to the logical inference span without installing an SDK.
with_inference_annotations(Work) ->
    {module, pig_otel} = code:ensure_loaded(pig_otel),
    Parent = self(),
    Recorder = spawn_link(fun() -> record(Parent, #{}, #{}, []) end),
    erlang:trace_pattern({pig_otel, start, 3}, [{'_', [], [{return_trace}]}], [local]),
    erlang:trace_pattern({pig_otel, annotate, 2}, true, [local]),
    erlang:trace(all, true, [call, set_on_spawn, {tracer, Recorder}]),
    try
        Work(),
        Barrier = erlang:trace_delivered(all),
        receive {trace_delivered, all, Barrier} -> ok after 5000 -> erlang:error(trace_barrier_timeout) end,
        Ref = make_ref(),
        Recorder ! {snapshot, Parent, Ref},
        receive {Ref, Annotations} -> Annotations after 5000 -> erlang:error(annotation_snapshot_timeout) end
    after
        erlang:trace(all, false, [call, set_on_spawn]),
        erlang:trace_pattern({pig_otel, start, 3}, false, [local]),
        erlang:trace_pattern({pig_otel, annotate, 2}, false, [local]),
        Recorder ! stop
    end.

is_inference({inference, _, _, _}) -> true;
is_inference({'Inference', _, _, _}) -> true;
is_inference(_) -> false.

record(Parent, Pending, Spans, Annotations) ->
    receive
        {trace, Pid, call, {pig_otel, start, [_, _, Operation]}} ->
            record(Parent, Pending#{Pid => Operation}, Spans, Annotations);
        {trace, Pid, return_from, {pig_otel, start, 3}, Span} ->
            Operation = maps:get(Pid, Pending),
            record(Parent, maps:remove(Pid, Pending), Spans#{Span => Operation}, Annotations);
        {trace, _, call, {pig_otel, annotate, [Span, Attributes]}} ->
            case is_inference(maps:get(Span, Spans, undefined)) of
                true ->
                    Text = iolist_to_binary(io_lib:format("~p", [Attributes])),
                    record(Parent, Pending, Spans, [Text | Annotations]);
                false -> record(Parent, Pending, Spans, Annotations)
            end;
        {snapshot, Requester, Ref} ->
            Requester ! {Ref, Annotations},
            record(Parent, Pending, Spans, Annotations);
        stop -> ok;
        _ -> record(Parent, Pending, Spans, Annotations)
    end.
