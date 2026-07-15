-module(pig_proxy_telemetry_ffi).

%% FFI for pig_proxy telemetry.
%%
%% Two responsibilities:
%%   - execute/3: emit an event to the BEAM :telemetry registry for EXTERNAL
%%     consumers (OTel, etc.). Called from the edge, after internal typed
%%     fanout, so the string/atom encoding stays out of the typed path.
%%   - typed-handler registry: a persistent_term list of Gleam
%%     `fn(ProxyEvent) -> Nil` handlers. The hot path is handlers_get/0 (a
%%     lock-free read inside `emit`); attach/detach are rare.

-export([
    ensure_started/0,
    execute/3,
    system_time/0,
    handlers_init/0,
    handlers_add/1,
    handlers_remove/1,
    handlers_get/0,
    handlers_call/2
]).

-define(HANDLERS_KEY, {pig_proxy, telemetry_handlers}).

%% Ensure the telemetry application is running.
ensure_started() ->
    case application:ensure_all_started(telemetry) of
        {ok, _} -> nil;
        {error, _} -> nil
    end.

execute(NameStrs, Measurements, Metadata) ->
    NameAtoms = [binary_to_atom(S, utf8) || S <- NameStrs],
    telemetry:execute(NameAtoms, atomize_keys(Measurements), atomize_keys(Metadata)),
    nil.

system_time() ->
    erlang:system_time(millisecond).

%% ── Typed-handler registry (persistent_term) ─────────────────────

%% Initialise the registry once without erasing handlers registered by a
%% running runtime or another supervised component.
handlers_init() ->
    case persistent_term:get(?HANDLERS_KEY, undefined) of
        undefined -> persistent_term:put(?HANDLERS_KEY, []);
        _ -> ok
    end,
    nil.

%% Register a Gleam handler; return an opaque ID for later removal.
handlers_add(Fn) ->
    Ref = make_ref(),
    Prev = persistent_term:get(?HANDLERS_KEY, []),
    persistent_term:put(?HANDLERS_KEY, [{Ref, Fn} | Prev]),
    {handler_id, Ref}.

%% Remove a previously registered handler by its ID.
handlers_remove({handler_id, Ref}) ->
    Prev = persistent_term:get(?HANDLERS_KEY, []),
    persistent_term:put(?HANDLERS_KEY, [H || H = {R, _} <- Prev, R =/= Ref]),
    nil.

%% Snapshot of the current handler list (hot path: called by `emit`).
handlers_get() ->
    persistent_term:get(?HANDLERS_KEY, []).

%% Invoke an untrusted Gleam callback without allowing it to crash the
%% emitter or prevent delivery to later handlers.
handlers_call(Fn, Event) ->
    try Fn(Event) of
        _ -> nil
    catch
        _:_ -> nil
    end.

%% Convert atom-keyed map to binary-keyed map with all values as binaries.
atomize_keys(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
        AtomKey = if is_binary(K) -> binary_to_atom(K, utf8); true -> K end,
        Acc#{AtomKey => V}
    end, #{}, Map).
