-module(pig_trace_test_ffi).
-behaviour(otel_tracer).
-export([no_sdk_setup/0, setup/0, teardown/0, snapshot/0, current_id/0, context_id/1,
         start_span/4, with_span/5, set_attributes/2, set_status/2, end_span/2,
         raised/1, exit_message/1, finally/2, double_failure/0]).
-include_lib("opentelemetry_api/include/opentelemetry.hrl").

%% Deterministic API recorder, not an SDK/exporter. SDK acceptance is separate.
setup() ->
    ets:new(pig_trace_test_spans, [named_table, public, ordered_set]),
    Parent = self(),
    Recorder = spawn(fun() ->
        true = register(otel_tracer_provider_global, self()),
        Parent ! recorder_ready,
        provider_loop()
    end),
    put(pig_test_recorder, Recorder),
    receive recorder_ready -> ok end,
    opentelemetry:set_text_map_propagator(
      otel_propagator_text_map_composite:create([trace_context, baggage])),
    otel_ctx:clear(),
    nil.

teardown() ->
    Recorder = erase(pig_test_recorder),
    case Recorder of
        undefined -> ok;
        _ ->
            Mon = monitor(process, Recorder),
            Recorder ! stop,
            receive {'DOWN', Mon, process, Recorder, _} -> ok end
    end,
    ets:delete(pig_trace_test_spans),
    otel_ctx:clear(),
    nil.

provider_loop() ->
    receive
        {'$gen_call', From, {get_tracer, Name, Version, Schema}} ->
            gen_server:reply(From, {?MODULE, {Name, Version, Schema}}),
            provider_loop();
        stop -> ok
    end.

start_span(Ctx, {_, {Scope, _, _}}, Name, Opts) ->
    Id = erlang:unique_integer([positive, monotonic]),
    Parent = otel_tracer:current_span_ctx(Ctx),
    ParentId = case Parent of #span_ctx{span_id=P} -> hex(P); _ -> <<>> end,
    TraceId = case Parent of #span_ctx{trace_id=T} when T =/= 0 -> T; _ -> Id end,
    Span = #span_ctx{trace_id=TraceId, span_id=Id,
                     hex_trace_id=otel_utils:encode_hex(<<TraceId:128>>),
                     hex_span_id=hex(Id), trace_flags=1,
                     is_valid=true, is_recording=true, span_sdk={?MODULE, []}},
    ets:insert(pig_trace_test_spans,
      {Id, Name, ParentId, maps:put(<<"test.scope">>, atom_to_binary(Scope), maps:get(attributes, Opts)), <<"unset">>, 0}),
    Span.

with_span(_, _, _, _, _) -> erlang:error(unexpected_callback_scoped_span).

set_attributes(#span_ctx{span_id=Id}, Values) ->
    [{Id, Name, Parent, Attrs, Status, Count}] = ets:lookup(pig_trace_test_spans, Id),
    ets:insert(pig_trace_test_spans, {Id, Name, Parent, maps:merge(Attrs, Values), Status, Count}),
    true.

set_status(#span_ctx{span_id=Id}, #status{code=Code}) ->
    ets:update_element(pig_trace_test_spans, Id, {5, atom_to_binary(Code)}),
    true.

end_span(#span_ctx{span_id=Id}, _) ->
    ets:update_counter(pig_trace_test_spans, Id, {6, 1}),
    true.

snapshot() ->
    [{snapshot, hex(Id), Name, Parent,
      lists:sort([{Key, format(Value)} || {Key, Value} <- maps:to_list(Attrs)]), Status, Count}
      || {Id, Name, Parent, Attrs, Status, Count} <- ets:tab2list(pig_trace_test_spans)].

current_id() -> context_id(otel_ctx:get_current()).
context_id(Ctx) ->
    case otel_tracer:current_span_ctx(Ctx) of #span_ctx{span_id=Id} -> hex(Id); _ -> <<>> end.
hex(Id) -> otel_utils:encode_hex(<<Id:64>>).
format(Value) when is_binary(Value) -> Value;
format(Value) -> iolist_to_binary(io_lib:format("~tp", [Value])).

raised(Work) ->
    try Work() of _ -> <<>>
    catch error:#{message := Message} -> Message;
          Class:Reason -> iolist_to_binary(io_lib:format("~tp:~tp", [Class, Reason]))
    end.

exit_message({abnormal, {#{message := Message}, _Stack}}) -> Message;
exit_message(Reason) -> format(Reason).

finally(Work, Cleanup) ->
    try Work() after Cleanup() end.

double_failure() ->
    pig_tracing_ffi:register(test_span),
    raised(fun() ->
        pig_tracing_ffi:protect(
          fun() -> erlang:error(#{message => <<"original hook failure">>}) end,
          fun(_) -> erlang:error(cleanup_failure) end)
    end).

no_sdk_setup() ->
    undefined = whereis(otel_tracer_provider_global),
    false = lists:keymember(opentelemetry, 1, application:which_applications()),
    ets:new(pig_trace_test_spans, [named_table, public, ordered_set]),
    opentelemetry:set_text_map_propagator(
      otel_propagator_text_map_composite:create([trace_context, baggage])),
    otel_ctx:clear(),
    nil.
