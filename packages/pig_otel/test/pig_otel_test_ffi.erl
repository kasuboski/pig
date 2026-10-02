-module(pig_otel_test_ffi).
-export([with_composite/1, unowned_marker/0, with_baggage/1, has_baggage/1,
         lookup_calls/1, start_calls/1, capture_diagnostics/1, sdk_absent/0,
         log/2, adding_handler/1, removing_handler/1, read_fixture/1, catch_work/1]).

%% Scope global test configuration and restore it even if an assertion fails.
with_composite(Work) ->
    Injector = opentelemetry:get_text_map_injector(),
    Extractor = opentelemetry:get_text_map_extractor(),
    Composite = otel_propagator_text_map_composite:create([trace_context, baggage]),
    opentelemetry:set_text_map_propagator(Composite),
    try Work()
    after
        opentelemetry:set_text_map_injector(Injector),
        opentelemetry:set_text_map_extractor(Extractor)
    end.

unowned_marker() -> fun erlang:node/0.

with_baggage(Context) ->
    otel_baggage:set(Context, <<"private">>, <<"must-not-propagate">>).

has_baggage(Context) -> map_size(otel_baggage:get_all(Context)) > 0.

lookup_calls(Work) -> count_calls({otel_gleam_ffi, tracer_for, 1}, Work).
start_calls(Work) -> count_calls({otel_gleam_ffi, start_span, 7}, Work).

%% Call counters are synchronous VM instrumentation, not message timing tests.
count_calls(MFA, Work) ->
    {module, otel_gleam_ffi} = code:ensure_loaded(otel_gleam_ffi),
    erlang:trace_pattern(MFA, true, [call_count]),
    try
        Value = Work(),
        {call_count, Count} = erlang:trace_info(MFA, call_count),
        {Value, Count}
    after
        erlang:trace_pattern(MFA, false, [call_count])
    end.

sdk_absent() ->
    code:which(otel_tracer_default) =:= non_existing andalso
        not lists:keymember(opentelemetry, 1, application:which_applications()).

capture_diagnostics(Work) ->
    Table = ets:new(pig_otel_diagnostics, [public, ordered_set]),
    ok = logger:add_handler(pig_otel_diagnostics, ?MODULE,
                            #{level => warning, config => #{table => Table}}),
    try
        Value = Work(),
        {Value, [Message || {_, Message} <- ets:tab2list(Table)]}
    after
        logger:remove_handler(pig_otel_diagnostics),
        ets:delete(Table)
    end.

adding_handler(Config) -> {ok, Config}.
removing_handler(_Config) -> ok.
log(#{msg := {string, Message}}, #{config := #{table := Table}}) ->
    ets:insert(Table, {erlang:unique_integer([monotonic]), unicode:characters_to_binary(Message)}),
    ok;
log(_, _) -> ok.

read_fixture(Path) ->
    case file:read_file(Path) of
        {ok, Contents} -> {ok, Contents};
        {error, _} -> {error, nil}
    end.

catch_work(Work) ->
    try Work() of
        Value -> {ok, Value}
    catch
        error:#{gleam_error := panic} -> {error, nil}
    end.
