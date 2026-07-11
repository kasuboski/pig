-module(pig_proxy_hackney_ffi).

%% Thin FFI wrappers around the hackney HTTP client.
%%
%% Two modes:
%%   - sync_request/5: blocking request that returns the full response.
%%   - stream_request_loop/7: streaming request that invokes Gleam callbacks
%%     for each body chunk, completion, and error. Must run in a dedicated
%%     process because it blocks until the stream ends.

-export([
    ensure_started/0,
    sync_request/5,
    stream_request_loop/7
]).

%% Stream body receive timeout (120 seconds).
-define(STREAM_TIMEOUT_MS, 120000).

%% Ensure the hackney application (and its dependencies) are running.
ensure_started() ->
    case application:ensure_all_started(hackney) of
        {ok, _} -> nil;
        {error, _} -> nil
    end.

%% Synchronous (buffered) request.
%% Returns {ok_response, Status, Headers, Body} or {error_response, Reason}.
sync_request(Method, Url, Headers, Body, TimeoutMs) ->
    Opts = [{recv_timeout, TimeoutMs}],
    case hackney:request(Method, Url, Headers, Body, Opts) of
        {ok, StatusCode, RespHeaders, Ref} ->
            case hackney:body(Ref) of
                {ok, RespBody} ->
                    {ok_response, StatusCode, RespHeaders, RespBody};
                {error, Reason} ->
                    {error_response, format_error(Reason)}
            end;
        {ok, StatusCode, RespHeaders} ->
            %% No body ref (e.g. HEAD) — return empty body.
            {ok_response, StatusCode, RespHeaders, <<>>};
        {error, Reason} ->
            {error_response, format_error(Reason)}
    end.

%% Streaming request with callbacks.
%%
%% Makes an async hackney request with stream_to self(), receives the
%% status and headers. If the status is 2xx, streams body chunks to
%% ChunkCb. If the status is non-2xx, reads the full body and calls
%% ErrorCb with a formatted error including the status code.
%%
%% Blocks until the stream ends or errors. MUST be called in a dedicated
%% process (the relay) so it doesn't block the request handler.
stream_request_loop(Method, Url, Headers, Body, ChunkCb, DoneCb, ErrorCb) ->
    case hackney:request(Method, Url, Headers, Body, [{stream_to, self()}, {async, true}]) of
        {ok, Ref} ->
            case receive_status_headers(Ref) of
                {ok, StatusCode} when StatusCode >= 200, StatusCode < 300 ->
                    stream_body(Ref, ChunkCb, DoneCb, ErrorCb);
                {ok, StatusCode} ->
                    %% Non-2xx status: read the full body and report as error.
                    ErrorBody = read_all_body(Ref),
                    ErrorCb(format_http_error(StatusCode, ErrorBody));
                {error, Reason} ->
                    ErrorCb(Reason)
            end;
        {error, Reason} ->
            ErrorCb(format_error(Reason))
    end.

%% Receive the initial {status, ...} and {headers, ...} messages.
%% Returns {ok, StatusCode} or {error, Reason}.
receive_status_headers(Ref) ->
    receive
        {hackney_response, Ref, {status, StatusCode, _Reason}} ->
            receive
                {hackney_response, Ref, {headers, _Headers}} ->
                    {ok, StatusCode};
                {hackney_response, Ref, {error, Reason}} ->
                    hackney:close(Ref),
                    {error, format_error(Reason)}
            after 30000 ->
                    hackney:close(Ref),
                    {error, <<"timeout waiting for upstream headers">>}
            end;
        {hackney_response, Ref, {error, Reason}} ->
            hackney:close(Ref),
            {error, format_error(Reason)}
    after 30000 ->
            hackney:close(Ref),
            {error, <<"timeout waiting for upstream status">>}
    end.

%% Stream body chunks to ChunkCb until done or error.
stream_body(Ref, ChunkCb, DoneCb, ErrorCb) ->
    receive
        {hackney_response, Ref, BinBodyPart} when is_binary(BinBodyPart) ->
            ChunkCb(BinBodyPart),
            stream_body(Ref, ChunkCb, DoneCb, ErrorCb);
        {hackney_response, Ref, done} ->
            hackney:close(Ref),
            DoneCb(nil);
        {hackney_response, Ref, {error, Reason}} ->
            hackney:close(Ref),
            ErrorCb(format_error(Reason));
        _Other ->
            %% Ignore unexpected messages.
            stream_body(Ref, ChunkCb, DoneCb, ErrorCb)
    after ?STREAM_TIMEOUT_MS ->
            hackney:close(Ref),
            ErrorCb(<<"stream timeout">>)
    end.

%% Read the full body for a non-2xx streaming response.
read_all_body(Ref) ->
    receive
        {hackney_response, Ref, BinBodyPart} when is_binary(BinBodyPart) ->
            <<BinBodyPart/binary, (read_all_body(Ref))/binary>>;
        {hackney_response, Ref, done} ->
            hackney:close(Ref),
            <<>>;
        {hackney_response, Ref, {error, _Reason}} ->
            hackney:close(Ref),
            <<>>;
        _Other ->
            read_all_body(Ref)
    after 30000 ->
            hackney:close(Ref),
            <<>>
    end.

%% Format an HTTP error (non-2xx status) for the Gleam ErrorCb.
format_http_error(StatusCode, Body) ->
    list_to_binary(io_lib:format("upstream returned ~w: ~s", [StatusCode, Body])).

%% Format an Erlang error term into a binary string for Gleam.
format_error(Reason) ->
    case Reason of
        timeout -> <<"timeout">>;
        closed -> <<"connection closed">>;
        {closed, Partial} when is_binary(Partial) ->
            <<"connection closed (partial body: ", Partial/binary, ")">>;
        _ ->
            list_to_binary(io_lib:format("~p", [Reason]))
    end.
