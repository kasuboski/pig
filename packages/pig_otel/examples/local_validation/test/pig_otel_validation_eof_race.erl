%% Supplemental real EOF-before-handoff fixture, using the production owner,
%% transport and SDK. The native spy observes adapter calls; it replaces none.
-module(pig_otel_validation_eof_race).
-export([check/1]).

check(Api) ->
    pig_proxy_trace_test_ffi:with_calls(fun(Recorder) ->
        Owners = 'support@tracing_harness':owners(),
        Ready = 'gleam@erlang@process':new_subject(),
        Source = 'gleam@erlang@process':new_subject(),
        Request = spawn(fun() ->
            Control = 'gleam@erlang@process':new_subject(),
            Owner = 'support@tracing_harness':owner(Owners, Api, metadata_only),
            Adapter = {transport, fun(_) -> {transport_error, <<"not buffered">>} end,
                fun(_, Sink) ->
                    Complete = 'gleam@erlang@process':new_subject(),
                    send(Source, Complete),
                    send(Sink, {source_head, 200, []}),
                    send(Sink, {source_chunk, <<"data: {}\n\n">>}),
                    nil = receive_subject(Complete),
                    send(Sink, {source_chunk, final(Api)}),
                    send(Sink, source_done),
                    send(Sink, source_done),
                    send(Sink, {source_error, <<"PRIVATE_LATE_ERROR">>})
                end},
            {committed_stream, Target, Provider, Status, _} =
                'pig_proxy@execution':orchestrate_stream(
                    'support@tracing_harness':executor(Adapter, Owner),
                    'support@tracing_harness':request(Api),
                    'support@tracing_harness':chain()),
            ack = pig_proxy_tracing_ffi:call(Owner, {select_stream, Target, Provider, Status}),
            send(Ready, {Owner, Control}),
            nil = receive_subject(Control)
        end),
        RequestMon = monitor(process, Request),
        {Owner, Control} = receive_subject(Ready),
        send(receive_subject(Source), nil),
        pig_proxy_trace_test_ffi:await_finishes(Recorder, 2),
        ChunkReady = 'gleam@erlang@process':new_subject(),
        Chunk = spawn(fun() ->
            Sink = 'gleam@erlang@process':new_subject(),
            ack = pig_proxy_tracing_ffi:call(Owner, {bind, Sink}),
            send(ChunkReady, nil),
            {body, cancelled} = receive_subject(Sink)
        end),
        ChunkMon = monitor(process, Chunk),
        nil = receive_subject(ChunkReady),
        pig_proxy_trace_test_ffi:wait_closed(Owner, fun() -> send(Control, nil) end),
        wait_retired(Request, RequestMon),
        wait_retired(Chunk, ChunkMon),
        Events = pig_proxy_trace_test_ffi:calls(Recorder),
        3 = length([E || E = {started, _, _, _} <- Events]),
        3 = length([E || E = {finished, _, _} <- Events]),
        nil
    end).

send(Subject, Message) -> 'gleam@erlang@process':send(Subject, Message).
receive_subject({subject, _, Ref}) ->
    receive {Ref, Message} -> Message
    after 5000 -> error(eof_race_ack_timeout) end.
wait_retired(Pid, Mon) ->
    receive {'DOWN', Mon, process, Pid, normal} -> ok;
            {'DOWN', Mon, process, Pid, Reason} -> error({eof_race_process_failed, Reason})
    after 5000 -> error(eof_race_retirement_timeout) end.

final(responses) ->
    <<"data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"model\":\"m\",\"status\":\"completed\",\"output\":\"PRIVATE_COMPLETION\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3,\"input_tokens_details\":{\"cached_tokens\":2}}}}\n\n">>;
final(chat_completions) ->
    <<"data: {\"id\":\"r\",\"model\":\"m\",\"choices\":[{\"finish_reason\":\"stop\",\"delta\":{\"content\":\"PRIVATE_COMPLETION\"}}],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3,\"prompt_tokens_details\":{\"cached_tokens\":2}}}\n\n">>.
