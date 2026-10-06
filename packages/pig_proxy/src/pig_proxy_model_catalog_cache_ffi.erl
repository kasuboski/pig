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
        Parsed = httpd_util:convert_request_date(binary_to_list(Header)),
        DateTime = correct_obsolete_year(Header, Parsed, NowMs),
        TargetSeconds = calendar:datetime_to_gregorian_seconds(DateTime) -
                        calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}),
        DelayMs = TargetSeconds * 1000 - NowMs,
        case DelayMs > 0 of true -> {some, DelayMs}; false -> none end
    catch
        _:_ -> none
    end.

%% RFC 9110: only RFC 850's two-digit years get the 50-year correction.
%% Explicit four-digit dates must retain their stated year.
correct_obsolete_year(Header, DateTime = {{Year, Month, Day}, Time}, NowMs) ->
    case re:run(Header, <<"^[A-Za-z]+, [0-9]{2}-[A-Za-z]{3}-[0-9]{2} ">>,
                [{capture, none}]) of
        match ->
            {{NowYear, NowMonth, NowDay}, NowTime} =
                calendar:system_time_to_universal_time(NowMs, millisecond),
            FiftyYearsLater = {{NowYear + 50, NowMonth, NowDay}, NowTime},
            case DateTime > FiftyYearsLater of
                true -> {{Year - 100, Month, Day}, Time};
                false -> DateTime
            end;
        nomatch -> DateTime
    end.
