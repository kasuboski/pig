-module(pig_proxy_io_ffi).

%% Tiny FFI for reading a line from stdin. gleam's `io` in the pinned
%% gleam_stdlib has no read_line; rather than upgrade the dep (which risks the
%% formatter churn seen elsewhere) we wrap Erlang's io:get_line. Used only by
%% the interactive `codex_login` manual-paste flow.

-export([read_line/1]).

read_line(Prompt) ->
    case io:get_line(Prompt) of
        eof -> <<>>;
        Line -> unicode:characters_to_binary(Line)
    end.
