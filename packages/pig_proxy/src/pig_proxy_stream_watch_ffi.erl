%% Domain-neutral source callback adapter. No tracing/binding code lives here.
-module(pig_proxy_stream_watch_ffi).
-export([stream/4]).

stream(Request, Relay, Watch, Callback) ->
    Source = self(),
    Ready = make_ref(),
    {Tap, TapMonitor} = spawn_monitor(fun() -> bootstrap(Source, Relay, Watch, Ready) end),
    receive
        {Ready, Subject, RelayPid} ->
            RelayMonitor = erlang:monitor(process, RelayPid),
            try Callback(Request, Subject) of
                _ ->
                    Finished = make_ref(),
                    Tap ! {callback_returned, self(), Finished},
                    receive
                        {Finished, acknowledged} -> ok;
                        {'DOWN', TapMonitor, process, Tap, _} -> ok
                    end,
                    %% Do not let the relay mistake normal source callback
                    %% retirement for failure before its ordered terminal.
                    receive {'DOWN', RelayMonitor, process, RelayPid, _} -> nil end
            after
                erlang:demonitor(TapMonitor, [flush]),
                erlang:demonitor(RelayMonitor, [flush])
            end;
        {'DOWN', TapMonitor, process, Tap, _} -> erlang:error(source_watch_bootstrap_failed)
    end.

bootstrap(Source, Relay, Watch, Ready) ->
    {ok, RelayPid} = 'gleam@erlang@process':subject_owner(Relay),
    {ok, WatchPid} = 'gleam@erlang@process':subject_owner(Watch),
    %% Both monitors exist before the callback receives its source subject.
    SourceMonitor = erlang:monitor(process, Source),
    RelayMonitor = erlang:monitor(process, RelayPid),
    WatchMonitor = erlang:monitor(process, WatchPid),
    {subject, WatchPid, WatchTag} = Watch,
    %% Register this neutral observer with the surviving owner before any
    %% vulnerable callback work. The owner monitors observer failure too.
    acknowledged = gen_server:call(WatchPid, {watch_bootstrap, WatchTag, self()}, infinity),
    Tag = make_ref(),
    Source ! {Ready, {subject, self(), Tag}, RelayPid},
    loop(Tag, SourceMonitor, RelayMonitor, WatchMonitor, Relay, Watch, false).

loop(Tag, SourceMonitor, RelayMonitor, WatchMonitor, Relay, Watch, Terminal) ->
    receive
        {Tag, Event} when not Terminal ->
            send(Watch, Event),
            send(Relay, Event),
            Done = Event =:= source_done orelse
                (is_tuple(Event) andalso element(1, Event) =:= source_error),
            loop(Tag, SourceMonitor, RelayMonitor, WatchMonitor, Relay, Watch, Done);
        {Tag, _Late} -> loop(Tag, SourceMonitor, RelayMonitor, WatchMonitor, Relay, Watch, Terminal);
        {callback_returned, Pid, Ref} ->
            case Terminal of
                false ->
                    Event = {source_error, <<"source callback returned without terminal">>},
                    send(Watch, Event), send(Relay, Event);
                true -> ok
            end,
            Pid ! {Ref, acknowledged},
            loop(Tag, SourceMonitor, RelayMonitor, WatchMonitor, Relay, Watch, true);
        {'DOWN', WatchMonitor, process, _, _} -> ok;
        {'DOWN', RelayMonitor, process, _, _} ->
            case Terminal of
                false -> send(Watch, {source_error, <<"stream relay stopped">>});
                true -> ok
            end;
        {'DOWN', SourceMonitor, process, _, _} ->
            case Terminal of
                false ->
                    Event = {source_error, <<"source callback exited unexpectedly">>},
                    send(Watch, Event), send(Relay, Event);
                true -> ok
            end
    end.

send(Subject, Event) -> 'gleam@erlang@process':send(Subject, Event).
