-module(pig_proxy_model_catalog_cache_ffi).
-export([cached/1, publish/2, jitter_per_mille/0, current_time_ms/0,
         retry_after_http_date_ms/2]).

%% Stable runtime names keep independent deployments' trusted catalogs apart.
cached(Name) -> persistent_term:get({?MODULE, Name}, pig_proxy@model_catalog:empty()).
publish(Name, Catalog) -> persistent_term:put({?MODULE, Name}, Catalog), nil.

%% Runtime-only entropy keeps independent BEAMs from retrying in lockstep.
jitter_per_mille() -> rand:uniform(1001) - 1.
current_time_ms() -> erlang:system_time(millisecond).

%% httpd_util decodes the HTTP-date; the supplied clock keeps the conversion
%% boundary explicit and returns only a positive remaining delay.
retry_after_http_date_ms(Header, NowMs) ->
    try
        DateTime = httpd_util:convert_request_date(binary_to_list(Header)),
        TargetSeconds = calendar:datetime_to_gregorian_seconds(DateTime) -
                        calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}),
        DelayMs = TargetSeconds * 1000 - NowMs,
        case DelayMs > 0 of true -> {some, DelayMs}; false -> none end
    catch
        _:_ -> none
    end.
