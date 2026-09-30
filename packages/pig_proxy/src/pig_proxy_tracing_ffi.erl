-module(pig_proxy_tracing_ffi).
-behaviour(gen_server).
-export([start_owner/1, call/2, sent/1, watch_subject/1, sink_subject/1, track_head/2, now_ms/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_owner(Registration) ->
    case gen_server:start_link(?MODULE, Registration, []) of
        {ok, Pid} -> {ok, {started, Pid, Pid}};
        {error, Reason} -> {error, {init_failed, iolist_to_binary(io_lib:format("~p", [Reason]))}}
    end.

call(Owner, Command) ->
    try gen_server:call(Owner, Command, infinity)
    catch
        exit:{noproc, _} when Command =:= shutdown -> ack;
        exit:{normal, _} when Command =:= shutdown -> ack;
        exit:{noproc, _} when is_tuple(Command), element(1, Command) =:= downstream -> ack;
        exit:{normal, _} when is_tuple(Command), element(1, Command) =:= downstream -> ack
    end.
sent(Owner) -> gen_server:cast(Owner, application_sent), nil.
now_ms() -> erlang:monotonic_time(millisecond).

watch_subject(Generation) -> subject({watch, Generation}).
sink_subject(Generation) -> subject({sink, Generation}).
track_head({subject, _, Ref}, Generation) -> put({trace_subject, Ref}, {sink, Generation}), nil.
subject(Kind) ->
    Ref = make_ref(),
    put({trace_subject, Ref}, Kind),
    {subject, self(), Ref}.

init(Registration) ->
    process_flag(trap_exit, true),
    %% No span is opened here. Parent monitoring precedes supervisor ack.
    Monitor = erlang:monitor(process, element(2, Registration)),
    State = pig_proxy@tracing:initialise(Registration),
    {ok, #{domain => State, request => Monitor, chunk => undefined, chunk_pid => undefined,
           watchers => #{}, accept_replies => [], terminal_replies => [], attempt_replies => [], activated => false}, 30000}.

handle_call({watch_bootstrap, Ref, Pid}, _From, State) ->
    case get({trace_subject, Ref}) of
        {watch, Generation} ->
            Monitor = erlang:monitor(process, Pid),
            Watchers = maps:get(watchers, State),
            {reply, acknowledged, State#{watchers => Watchers#{Monitor => Generation}}};
        _ -> {reply, refused, State}
    end;
handle_call({bind, _}, _From, State = #{chunk := Monitor}) when Monitor =/= undefined ->
    {reply, ack, State};
handle_call({bind, Sink} = Command, _From, State) ->
    {ok, Pid} = 'gleam@erlang@process':subject_owner(Sink),
    Monitor = erlang:monitor(process, Pid),
    transition(Command, State#{chunk => Monitor, chunk_pid => Pid});
handle_call(handoff_receipt, {Pid, _}, State = #{chunk_pid := Chunk}) when Pid =/= Chunk ->
    {reply, ack, State};
handle_call(accepted = Command, From, State) ->
    {Next, Reply} = pig_proxy@tracing:command(maps:get(domain, State), Command),
    case pig_proxy@tracing:awaiting_receipt(Next) of
        true ->
            %% The starter cannot return Mist's marker until the surviving
            %% owner has received the chunk's receipt. Never block this loop.
            Waiters = maps:get(accept_replies, State),
            {noreply, State#{domain => Next, accept_replies => [From | Waiters]}};
        false -> {reply, Reply, State#{domain => Next}}
    end;
handle_call(handoff_receipt = Command, From, State) ->
    {Next, Reply} = pig_proxy@tracing:command(maps:get(domain, State), Command),
    %% Receipt acknowledgement retires ONLY the request monitor. The chunk
    %% monitor already exists and remains authoritative for downstream death.
    case pig_proxy@tracing:handoff_complete(Next) of
        true ->
            case maps:get(request, State) of
                undefined -> ok;
                Monitor -> erlang:demonitor(Monitor, [flush])
            end,
            gen_server:reply(From, Reply),
            lists:foreach(fun(Waiter) -> gen_server:reply(Waiter, ack) end,
                          maps:get(accept_replies, State)),
            {noreply, State#{domain => Next, request => undefined, accept_replies => []}};
        false -> {reply, Reply, State#{domain => Next}}
    end;
handle_call(abort_attempt = Command, From, State) ->
    {Next, Reply} = pig_proxy@tracing:command(maps:get(domain, State), Command),
    case pig_proxy@tracing:attempt_finished(Next) of
        true -> {reply, Reply, State#{domain => Next}};
        false ->
            Waiters = maps:get(attempt_replies, State),
            {noreply, State#{domain => Next, attempt_replies => [From | Waiters]}}
    end;
handle_call({downstream, _} = Command, From, State) -> stop_command(Command, From, State);
handle_call(shutdown = Command, From, State) -> stop_command(Command, From, State);
handle_call(Command, _From, State) -> transition(Command, State).

transition(Command, State) ->
    {Next, Reply} = pig_proxy@tracing:command(maps:get(domain, State), Command),
    {reply, Reply, State#{domain => Next, activated => true}}.

stop_command(Command, From, State) ->
    {Next, Reply} = pig_proxy@tracing:command(maps:get(domain, State), Command),
    case pig_proxy@tracing:finished(Next) of
        true -> {stop, normal, Reply, State#{domain => Next}};
        false ->
            Waiters = maps:get(terminal_replies, State),
            {noreply, State#{domain => Next, terminal_replies => [From | Waiters]}}
    end.

handle_cast(application_sent, State) ->
    Next = pig_proxy@tracing:application_sent(maps:get(domain, State)),
    {noreply, State#{domain => Next}}.

handle_info({'DOWN', Ref, process, _, Reason}, State) ->
    case Ref =:= maps:get(request, State) orelse Ref =:= maps:get(chunk, State) of
        true ->
            Next = pig_proxy@tracing:cleanup(maps:get(domain, State), death_outcome(Reason)),
            finish_info(State#{domain => Next});
        false ->
            case maps:take(Ref, maps:get(watchers, State)) of
                {Generation, Watchers} ->
                    Next = pig_proxy@tracing:observer_exited(maps:get(domain, State), Generation),
                    finish_info(State#{domain => Next, watchers => Watchers});
                error -> {noreply, State}
            end
    end;
handle_info({Ref, Event}, State) when is_reference(Ref) ->
    Domain = maps:get(domain, State),
    Next = case get({trace_subject, Ref}) of
        {watch, Generation} -> pig_proxy@tracing:source(Domain, Generation, Event);
        {sink, Generation} -> pig_proxy@tracing:generation_event(Domain, Generation, Event);
        _ -> Domain
    end,
    finish_info(State#{domain => Next});
handle_info(timeout, State = #{activated := false}) -> {stop, normal, State};
handle_info(_, State) -> {noreply, State}.

finish_info(State0) ->
    State = case pig_proxy@tracing:attempt_finished(maps:get(domain, State0)) of
        true ->
            lists:foreach(fun(Waiter) -> gen_server:reply(Waiter, ack) end,
                          maps:get(attempt_replies, State0)),
            State0#{attempt_replies => []};
        false -> State0
    end,
    case pig_proxy@tracing:finished(maps:get(domain, State)) of
        true ->
            lists:foreach(fun(Waiter) -> gen_server:reply(Waiter, ack) end,
                          maps:get(terminal_replies, State)),
            {stop, normal, State};
        false -> {noreply, State}
    end.

terminate(Reason, State) ->
    Category = case Reason of normal -> <<"client_disconnected">>; _ -> <<"agent_stopped">> end,
    Next = pig_proxy@tracing:cleanup(maps:get(domain, State), {cancelled, Category}),
    %% Supervisor shutdown uses the same upstream terminal boundary. Cleanup
    %% is bounded below the supervisor's 5-second brutal-kill deadline.
    retire(State#{domain => Next}, now_ms() + 4000),
    ok.

retire(State0, Deadline) ->
    State = case pig_proxy@tracing:attempt_finished(maps:get(domain, State0)) of
        true ->
            lists:foreach(fun(Waiter) -> gen_server:reply(Waiter, ack) end,
                          maps:get(attempt_replies, State0)),
            State0#{attempt_replies => []};
        false -> State0
    end,
    case pig_proxy@tracing:finished(maps:get(domain, State)) of
        true ->
            lists:foreach(fun(Waiter) -> gen_server:reply(Waiter, ack) end,
                          maps:get(terminal_replies, State));
        false ->
            Remaining = max(0, Deadline - now_ms()),
            receive
                {'$gen_call', From, {watch_bootstrap, Ref, Pid}} ->
                    case get({trace_subject, Ref}) of
                        {watch, Generation} ->
                            Monitor = erlang:monitor(process, Pid),
                            Watchers = maps:get(watchers, State),
                            gen_server:reply(From, acknowledged),
                            retire(State#{watchers => Watchers#{Monitor => Generation}}, Deadline);
                        _ -> gen_server:reply(From, refused), retire(State, Deadline)
                    end;
                {Ref, Event} when is_reference(Ref) ->
                    Domain = maps:get(domain, State),
                    Next = case get({trace_subject, Ref}) of
                        {watch, Generation} -> pig_proxy@tracing:source(Domain, Generation, Event);
                        {sink, Generation} -> pig_proxy@tracing:generation_event(Domain, Generation, Event);
                        _ -> Domain
                    end,
                    retire(State#{domain => Next}, Deadline);
                {'DOWN', Ref, process, _, _} ->
                    case maps:take(Ref, maps:get(watchers, State)) of
                        {Generation, Watchers} ->
                            Next = pig_proxy@tracing:observer_exited(maps:get(domain, State), Generation),
                            retire(State#{domain => Next, watchers => Watchers}, Deadline);
                        error -> retire(State, Deadline)
                    end;
                _ -> retire(State, Deadline)
            after Remaining ->
                Final = pig_proxy@tracing:cancellation_deadline(maps:get(domain, State)),
                retire(State#{domain => Final}, Deadline)
            end
    end.

death_outcome(normal) -> {cancelled, <<"client_disconnected">>};
death_outcome(noproc) -> {cancelled, <<"client_disconnected">>};
death_outcome(killed) -> {cancelled, <<"client_disconnected">>};
death_outcome(shutdown) -> {cancelled, <<"agent_stopped">>};
death_outcome({#{gleam_error := panic}, _}) -> {failed, <<"callback_error">>};
death_outcome(_) -> {failed, <<"process_exit">>}.

code_change(_, State, _) -> {ok, State}.
