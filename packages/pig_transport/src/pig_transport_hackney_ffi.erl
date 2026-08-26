-module(pig_transport_hackney_ffi).

%% Hackney is deliberately kept behind this adapter. The caller-facing relay
%% lifecycle lives in pig_transport; this process only turns Hackney messages
%% into ordered source events and closes its request when cancelled.

-export([ensure_started/0, sync_request/5, stream_connect/6]).

ensure_started() ->
    case application:ensure_all_started(hackney) of
        {ok, _} -> nil;
        {error, _} -> nil
    end.

sync_request(Method, Url, Headers, Body, TimeoutMs) ->
    Opts = [{recv_timeout, TimeoutMs}],
    case hackney:request(Method, Url, Headers, Body, Opts) of
        {ok, StatusCode, RespHeaders, Ref} ->
            case hackney:body(Ref) of
                {ok, RespBody} ->
                    {response, StatusCode, RespHeaders, RespBody};
                {error, Reason} ->
                    {transport_error, format_error(Reason)}
            end;
        {ok, StatusCode, RespHeaders} ->
            {response, StatusCode, RespHeaders, <<>>};
        {error, Reason} ->
            {transport_error, format_error(Reason)}
    end.

%% Start a streaming Hackney request. The source control subject is created
%% in this process so its messages can be received while Hackney is blocked.
stream_connect(Method, Url, Headers, Body, TimeoutMs, SourceSubject) ->
    Control = new_subject(),
    send_source(SourceSubject, {source_ready, Control}),
    Opts = [{stream_to, self()}, {async, true}, {recv_timeout, TimeoutMs}],
    case hackney:request(Method, Url, Headers, Body, Opts) of
        {ok, Ref} ->
            case receive_status_headers(Ref, Control, TimeoutMs) of
                {ok, StatusCode, RespHeaders} when StatusCode >= 200,
                                                   StatusCode < 300 ->
                    receive_first_and_forward(Ref, StatusCode, RespHeaders,
                                              SourceSubject, Control, TimeoutMs);
                {ok, StatusCode, RespHeaders} ->
                    case read_all_body(Ref, Control, TimeoutMs) of
                        {ok, FullBody} ->
                            hackney:close(Ref),
                            send_source(SourceSubject,
                                {source_head, StatusCode, RespHeaders}),
                            send_source(SourceSubject, {source_chunk, FullBody}),
                            send_source(SourceSubject, source_done);
                        cancelled ->
                            hackney:close(Ref),
                            ok;
                        timeout ->
                            hackney:close(Ref),
                            send_source(SourceSubject,
                                {source_error, <<"timeout reading upstream error body">>});
                        {error, Reason} ->
                            hackney:close(Ref),
                            send_source(SourceSubject, {source_error, Reason})
                    end;
                {error, Reason} ->
                    hackney:close(Ref),
                    send_source(SourceSubject, {source_error, Reason});
                cancelled ->
                    hackney:close(Ref),
                    ok
            end;
        {error, Reason} ->
            send_source(SourceSubject, {source_error, format_error(Reason)})
    end.

receive_status_headers(Ref, Control, TimeoutMs) ->
    ControlTag = subject_tag(Control),
    receive
        {ControlTag, cancel_source} -> cancelled;
        {hackney_response, Ref, {status, StatusCode, _Reason}} ->
            receive
                {ControlTag, cancel_source} -> cancelled;
                {hackney_response, Ref, {headers, Headers}} ->
                    {ok, StatusCode, Headers};
                {hackney_response, Ref, {error, Reason}} ->
                    {error, format_error(Reason)}
            after TimeoutMs ->
                    {error, <<"timeout waiting for upstream headers">>}
            end;
        {hackney_response, Ref, {error, Reason}} ->
            {error, format_error(Reason)}
    after TimeoutMs ->
            {error, <<"timeout waiting for upstream status">>}
    end.

%% A committed head is emitted only after the first body event is available.
%% The relay owns the first chunk until its consumer calls start.
receive_first_and_forward(Ref, Status, Headers, SourceSubject, Control, TimeoutMs) ->
    ControlTag = subject_tag(Control),
    receive
        {ControlTag, cancel_source} ->
            hackney:close(Ref),
            ok;
        {hackney_response, Ref, BinBodyPart} when is_binary(BinBodyPart) ->
            send_source(SourceSubject, {source_head, Status, Headers}),
            send_source(SourceSubject, {source_chunk, BinBodyPart}),
            forward_loop(Ref, SourceSubject, Control, TimeoutMs);
        {hackney_response, Ref, done} ->
            send_source(SourceSubject, {source_head, Status, Headers}),
            send_source(SourceSubject, source_done),
            hackney:close(Ref);
        {hackney_response, Ref, {error, Reason}} ->
            hackney:close(Ref),
            send_source(SourceSubject, {source_error, format_error(Reason)})
    after TimeoutMs ->
            hackney:close(Ref),
            send_source(SourceSubject,
                {source_error, <<"timeout waiting for first byte">>})
    end.

forward_loop(Ref, SourceSubject, Control, TimeoutMs) ->
    ControlTag = subject_tag(Control),
    receive
        {ControlTag, cancel_source} ->
            hackney:close(Ref),
            ok;
        {hackney_response, Ref, BinBodyPart} when is_binary(BinBodyPart) ->
            send_source(SourceSubject, {source_chunk, BinBodyPart}),
            forward_loop(Ref, SourceSubject, Control, TimeoutMs);
        {hackney_response, Ref, done} ->
            send_source(SourceSubject, source_done),
            hackney:close(Ref);
        {hackney_response, Ref, {error, Reason}} ->
            send_source(SourceSubject, {source_error, format_error(Reason)}),
            hackney:close(Ref);
        _Other ->
            forward_loop(Ref, SourceSubject, Control, TimeoutMs)
    after TimeoutMs ->
            send_source(SourceSubject, {source_error, <<"stream timeout">>}),
            hackney:close(Ref)
    end.

%% Non-2xx bodies are fully consumed before the rejection head is delivered.
read_all_body(Ref, Control, TimeoutMs) ->
    ControlTag = subject_tag(Control),
    receive
        {ControlTag, cancel_source} -> cancelled;
        {hackney_response, Ref, BinBodyPart} when is_binary(BinBodyPart) ->
            case read_all_body(Ref, Control, [BinBodyPart], TimeoutMs) of
                {ok, Body} -> {ok, Body};
                cancelled -> cancelled;
                {error, Reason} -> {error, Reason}
            end;
        {hackney_response, Ref, done} ->
            {ok, <<>>};
        {hackney_response, Ref, {error, Reason}} ->
            {error, format_error(Reason)}
    after TimeoutMs ->
            timeout
    end.

read_all_body(Ref, Control, Acc, TimeoutMs) ->
    ControlTag = subject_tag(Control),
    receive
        {ControlTag, cancel_source} -> cancelled;
        {hackney_response, Ref, BinBodyPart} when is_binary(BinBodyPart) ->
            read_all_body(Ref, Control, [BinBodyPart | Acc], TimeoutMs);
        {hackney_response, Ref, done} ->
            {ok, iolist_to_binary(lists:reverse(Acc))};
        {hackney_response, Ref, {error, Reason}} ->
            {error, format_error(Reason)}
    after TimeoutMs ->
            timeout
    end.

new_subject() ->
    {subject, self(), erlang:make_ref()}.

subject_tag({subject, _Pid, Tag}) ->
    Tag.

send_source({subject, Pid, Tag}, Message) ->
    Pid ! {Tag, Message},
    ok.

format_error(Reason) ->
    case Reason of
        timeout -> <<"timeout">>;
        closed -> <<"connection closed">>;
        {closed, Partial} when is_binary(Partial) ->
            <<"connection closed (partial body: ", Partial/binary, ")">>;
        _ ->
            list_to_binary(io_lib:format("~p", [Reason]))
    end.
