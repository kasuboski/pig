-module(pig_obs_ffi).

%% Minimal FFI: thin wrappers around :telemetry and :erlang.
%% All event naming and metadata shaping lives in Gleam.

-export([
    execute/3,
    system_time/0,
    attach_listener/1,
    get_captured_names/1,
    get_captured_events/1,
    get_captured_count/1,
    detach_listener/1
]).

%% Execute a telemetry event.
%% Converts string-keyed maps (from Gleam Dict) to atom-keyed maps (required by :telemetry).
%% Converts string event name segments to atoms.
execute(NameStrs, Measurements, Metadata) ->
    NameAtoms = [binary_to_atom(S, utf8) || S <- NameStrs],
    telemetry:execute(NameAtoms, atomize_keys(Measurements), atomize_keys(Metadata)),
    nil.

%% Erlang monotonic time for measurements.
system_time() ->
    erlang:system_time().

%% Attach a listener that captures full event data into an ETS table.
%% Stores {Timestamp, NameStrs, Measurements, Metadata} per event.
%% Returns {HandlerId, TableId} as the opaque handle.
attach_listener(EventNamesStrs) ->
    TableId = ets:new(pig_listener, [ordered_set, public]),
    Handler = fun(EventName, Measurements, Metadata, _Config) ->
        NameStrs = [atom_to_binary(E, utf8) || E <- EventName],
        BinMeasurements = deatomize_keys(Measurements),
        BinMetadata = deatomize_keys(Metadata),
        ets:insert(TableId, {erlang:unique_integer([monotonic]), NameStrs, BinMeasurements, BinMetadata})
    end,
    AtomNames = [[binary_to_atom(S, utf8) || S <- Name] || Name <- EventNamesStrs],
    HandlerId = {pig_listener, TableId},
    telemetry:attach_many(HandlerId, AtomNames, Handler, undefined),
    {HandlerId, TableId}.

%% Get the list of captured event names (in order).
get_captured_names({_, TableId}) ->
    Rows = ets:tab2list(TableId),
    [NameStrs || {_, NameStrs, _, _} <- Rows].

%% Get captured events as Gleam-compatible tuples.
%% Returns a list of {raw_captured_event, Name, Measurements, Metadata} tuples
%% which Gleam sees as List(RawCapturedEvent).
get_captured_events({_, TableId}) ->
    Rows = ets:tab2list(TableId),
    [{raw_captured_event, NameStrs, Measurements, Metadata}
     || {_, NameStrs, Measurements, Metadata} <- Rows].

%% Get the count of captured events.
get_captured_count({_, TableId}) ->
    ets:info(TableId, size).

%% Detach the listener and clean up the ETS table.
detach_listener({HandlerId, TableId}) ->
    telemetry:detach(HandlerId),
    ets:delete(TableId),
    nil.

%% Internal: convert string-keyed map to atom-keyed map (for emitting).
atomize_keys(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
        AtomKey = if is_binary(K) -> binary_to_atom(K, utf8); true -> K end,
        Acc#{AtomKey => V}
    end, #{}, Map).

%% Internal: convert atom-keyed map to binary-keyed map (for capturing back to Gleam).
deatomize_keys(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
        BinKey = if is_atom(K) -> atom_to_binary(K, utf8); true -> K end,
        Acc#{BinKey => V}
    end, #{}, Map).
