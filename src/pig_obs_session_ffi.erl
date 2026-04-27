-module(pig_obs_session_ffi).
-export([iso_timestamp/0]).

%% Get current ISO 8601 timestamp (RFC3339 format).
%% Returns a binary (string) instead of a charlist.
iso_timestamp() ->
    Charlist = calendar:system_time_to_rfc3339(os:system_time(second), []),
    unicode:characters_to_binary(Charlist, utf8).
