-module(pig_proxy_json_ffi).

%% JSON round-trip helpers used by the proxy. Gleam's JSON decoder cannot
%% preserve arbitrary JSON fields, so these small Erlang helpers mutate a
%% decoded object and re-encode it.
%%
%% Uses the Erlang `json` module shipped with OTP 27+.

-export([ensure_stream_usage/1]).

%% If `Body` is a JSON object, ensure it contains `stream_options` with
%% `include_usage: true`. Existing `stream_options` keys are preserved. On any
%% decode failure, return the original body unchanged.
ensure_stream_usage(Body) ->
    try
        Value = json:decode(Body),
        case is_map(Value) of
            true ->
                RawStreamOptions = maps:get(<<"stream_options">>, Value, #{}),
                %% A client may send stream_options as null, a list, or some
                %% other non-map value; coerce to an empty map so the update
                %% below cannot crash and drop the whole transformation.
                StreamOptions = case is_map(RawStreamOptions) of
                    true -> RawStreamOptions;
                    false -> #{}
                end,
                NewStreamOptions = StreamOptions#{<<"include_usage">> => true},
                NewValue = Value#{<<"stream_options">> => NewStreamOptions},
                iolist_to_binary(json:encode(NewValue));
            false ->
                Body
        end
    catch
        _:_ ->
            Body
    end.
