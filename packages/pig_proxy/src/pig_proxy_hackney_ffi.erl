-module(pig_proxy_hackney_ffi).

%% Thin FFI wrappers around the hackney HTTP client.
%%
%% Two modes:
%%   - sync_request/5: blocking request that returns the full response.
%%   - stream_connect/5: opens a streaming request, reports the head
%%     (status + first byte) synchronously to a gleam/erlang Subject, then
%%     waits to be "started" before forwarding the body. This lets request
%%     execution decide retry/fallback/commit BEFORE any byte reaches the
%%     client, while the mist chunked loop still owns the forwarding sink.
%%
%% Message shapes mirror the Gleam custom types in pig_proxy/transport:
%%   head    -> {stream_committed, Status, Headers, RunSubject}
%%              {stream_rejected,  Status, Headers, Body}
%%              {stream_failure,   Reason}
%%   control -> {start_relay, ForwardSubject}        (sent TO the relay)
%%   forward -> {relay_chunk, Bin} | relay_done | {relay_error, Reason}
%%
%% A gleam/erlang Subject is {subject, Pid, Tag}; a message is sent as
%% the tagged tuple {Tag, Message} to Pid (see gleam_erlang_ffi).

-export([
    ensure_started/0,
    sync_request/5,
    stream_connect/5
]).

%% Per-receive timeouts.
-define(HEAD_TIMEOUT_MS, 30000).
-define(STREAM_TIMEOUT_MS, 120000).
%% How long a committed relay waits for StartRelay before giving up, so a
%% relay whose consumer never starts (e.g. a crash) does not leak.
-define(START_TIMEOUT_MS, 30000).

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

%% Open a streaming request and report the head to HeadSubject synchronously.
%%
%%   2xx head + first byte  -> {stream_committed, Status, Headers, RunSubject}
%%                             then PAUSE until StartRelay, then forward.
%%   2xx head, empty body   -> {stream_committed, ...} then forward relay_done.
%%   non-2xx head           -> {stream_rejected, Status, Headers, FullBody}.
%%   connect failure        -> {stream_failure, Reason}.
%%
%% MUST run in a dedicated process (the relay): it blocks until the stream
%% ends after being started.
stream_connect(Method, Url, Headers, Body, HeadSubject) ->
    case hackney:request(Method, Url, Headers, Body, [{stream_to, self()}, {async, true}]) of
        {ok, Ref} ->
            case receive_status_headers(Ref) of
                {ok, StatusCode, RespHeaders}
                    when StatusCode >= 200, StatusCode < 300 ->
                    receive_first_and_report(Ref, StatusCode, RespHeaders, HeadSubject);
                {ok, StatusCode, RespHeaders} ->
                    case read_all_body(Ref) of
                        {ok, FullBody} ->
                            send_subject(HeadSubject,
                                {stream_rejected, StatusCode, RespHeaders, FullBody});
                        {timeout, _PartialBody} ->
                            send_subject(HeadSubject,
                                {stream_failure, <<"timeout reading upstream error body">>})
                    end;
                {error, Reason} ->
                    send_subject(HeadSubject, {stream_failure, Reason})
            end;
        {error, Reason} ->
            send_subject(HeadSubject, {stream_failure, format_error(Reason)})
    end.

%% Receive the initial {status, ...} and {headers, ...} messages.
receive_status_headers(Ref) ->
    receive
        {hackney_response, Ref, {status, StatusCode, _Reason}} ->
            receive
                {hackney_response, Ref, {headers, Headers}} ->
                    {ok, StatusCode, Headers};
                {hackney_response, Ref, {error, Reason}} ->
                    hackney:close(Ref),
                    {error, format_error(Reason)}
            after ?HEAD_TIMEOUT_MS ->
                    hackney:close(Ref),
                    {error, <<"timeout waiting for upstream headers">>}
            end;
        {hackney_response, Ref, {error, Reason}} ->
            hackney:close(Ref),
            {error, format_error(Reason)}
    after ?HEAD_TIMEOUT_MS ->
            hackney:close(Ref),
            {error, <<"timeout waiting for upstream status">>}
    end.

%% Confirm commit by observing the first body event, report the head, then
%% hand off to the start/forward phase.
receive_first_and_report(Ref, Status, Headers, HeadSubject) ->
    receive
        {hackney_response, Ref, BinBodyPart} when is_binary(BinBodyPart) ->
            RunSubject = new_subject(),
            send_subject(HeadSubject, {stream_committed, Status, Headers, RunSubject}),
            wait_start_and_forward(Ref, BinBodyPart, RunSubject);
        {hackney_response, Ref, done} ->
            RunSubject = new_subject(),
            send_subject(HeadSubject, {stream_committed, Status, Headers, RunSubject}),
            wait_start_and_finish_empty(Ref, RunSubject);
        {hackney_response, Ref, {error, Reason}} ->
            hackney:close(Ref),
            send_subject(HeadSubject, {stream_failure, format_error(Reason)})
    after ?HEAD_TIMEOUT_MS ->
            hackney:close(Ref),
            send_subject(HeadSubject, {stream_failure, <<"timeout waiting for first byte">>})
    end.

%% Hold the first byte, wait for StartRelay, then forward it and continue.
wait_start_and_forward(Ref, FirstChunk, RunSubject) ->
    RunTag = subject_tag(RunSubject),
    receive
        {RunTag, {start_relay, Fwd}} ->
            send_subject(Fwd, {relay_chunk, FirstChunk}),
            forward_loop(Ref, Fwd)
    after ?START_TIMEOUT_MS ->
            hackney:close(Ref),
            ok
    end.

%% A committed empty stream: wait for StartRelay, then report done.
wait_start_and_finish_empty(Ref, RunSubject) ->
    RunTag = subject_tag(RunSubject),
    receive
        {RunTag, {start_relay, Fwd}} ->
            send_subject(Fwd, relay_done),
            hackney:close(Ref),
            ok
    after ?START_TIMEOUT_MS ->
            hackney:close(Ref),
            ok
    end.

%% Forward subsequent chunks to the consumer subject until done or error.
forward_loop(Ref, Fwd) ->
    receive
        {hackney_response, Ref, BinBodyPart} when is_binary(BinBodyPart) ->
            send_subject(Fwd, {relay_chunk, BinBodyPart}),
            forward_loop(Ref, Fwd);
        {hackney_response, Ref, done} ->
            send_subject(Fwd, relay_done),
            hackney:close(Ref);
        {hackney_response, Ref, {error, Reason}} ->
            send_subject(Fwd, {relay_error, format_error(Reason)}),
            hackney:close(Ref);
        _Other ->
            %% Ignore unexpected messages (e.g. a late start_relay echo).
            forward_loop(Ref, Fwd)
    after ?STREAM_TIMEOUT_MS ->
            send_subject(Fwd, {relay_error, <<"stream timeout">>}),
            hackney:close(Ref)
    end.

%% Read the full body for a non-2xx streaming response.
%% Tail-recursive: accumulates chunks in an iolist, then flattens once.
%% Returns `{ok, Body}` on completion and `{timeout, PartialBody}` on idle timeout.
read_all_body(Ref) ->
    read_all_body(Ref, []).

read_all_body(Ref, Acc) ->
    receive
        {hackney_response, Ref, BinBodyPart} when is_binary(BinBodyPart) ->
            read_all_body(Ref, [BinBodyPart | Acc]);
        {hackney_response, Ref, done} ->
            hackney:close(Ref),
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {hackney_response, Ref, {error, _Reason}} ->
            hackney:close(Ref),
            {ok, iolist_to_binary(lists:reverse(Acc))};
        _Other ->
            read_all_body(Ref, Acc)
    after ?HEAD_TIMEOUT_MS ->
            hackney:close(Ref),
            {timeout, iolist_to_binary(lists:reverse(Acc))}
    end.

%% Construct a gleam/erlang Subject owned by this process.
new_subject() ->
    {subject, self(), erlang:make_ref()}.

%% The tag of a gleam/erlang Subject.
subject_tag({subject, _Pid, Tag}) ->
    Tag.

%% Send a Gleam message to a gleam/erlang Subject: Pid ! {Tag, Message}.
send_subject({subject, Pid, Tag}, Message) ->
    Pid ! {Tag, Message},
    ok.

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
