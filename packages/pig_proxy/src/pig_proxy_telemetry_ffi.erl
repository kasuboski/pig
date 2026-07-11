-module(pig_proxy_telemetry_ffi).

%% Thin FFI for :telemetry.execute/3, mirroring pig_obs_ffi.
%% Converts string-keyed maps to atom-keyed maps and string event
%% name segments to atoms.

-export([execute/3, system_time/0, attach_forwarder/2, detach_forwarder/1]).

execute(NameStrs, Measurements, Metadata) ->
    NameAtoms = [binary_to_atom(S, utf8) || S <- NameStrs],
    telemetry:execute(NameAtoms, atomize_keys(Measurements), atomize_keys(Metadata)),
    nil.

system_time() ->
    erlang:system_time(millisecond).

%% Attach a telemetry handler that forwards events to a process as
%% {proxy_metrics_event, NameStrs, MeasurementsStrs, MetadataStrs}.
%% Returns an opaque handler ID for later detachment.
attach_forwarder(Pid, EventNamesStrs) ->
    Handler = fun(EventName, Measurements, Metadata, _Config) ->
        NameStrs = [atom_to_binary(E, utf8) || E <- EventName],
        Pid ! {proxy_metrics_event, NameStrs,
               deatomize_to_strings(Measurements),
               deatomize_to_strings(Metadata)},
        ok
    end,
    AtomNames = [[binary_to_atom(S, utf8) || S <- Name] || Name <- EventNamesStrs],
    HandlerId = {pig_proxy_forwarder, make_ref()},
    telemetry:attach_many(HandlerId, AtomNames, Handler, undefined),
    HandlerId.

detach_forwarder(HandlerId) ->
    telemetry:detach(HandlerId),
    nil.

%% Convert atom-keyed map to binary-keyed map with all values as binaries.
deatomize_to_strings(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
        BinKey = if is_atom(K) -> atom_to_binary(K, utf8); true -> K end,
        BinVal = if
            is_integer(V) -> integer_to_binary(V);
            is_atom(V) -> atom_to_binary(V, utf8);
            is_binary(V) -> V;
            true -> list_to_binary(io_lib:format("~p", [V]))
        end,
        Acc#{BinKey => BinVal}
    end, #{}, Map).

atomize_keys(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
        AtomKey = if is_binary(K) -> binary_to_atom(K, utf8); true -> K end,
        Acc#{AtomKey => V}
    end, #{}, Map).
