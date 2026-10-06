-module(pig_otel_content_ffi).

%% Pure domain adapter, not an OTel binding. Every public data boundary catches
%% failures and drops content. No process dictionary, callbacks, or side effects.
-export([defaults/0, with_limits/3, with_direction_limits/2, with_redacted_keys/2,
         with_redacted_text/2, input/3, buffered/3, pairs/2,
         new_stream/2, push/2, finish/2, retained_bytes/1,
         normalized_input/4, normalized_output/3, incomplete/0]).

-define(MAX_NODES, 4096).
-define(MAX_DEPTH, 32).
-define(REDACTED, <<"[REDACTED]">>).

defaults() ->
    {options, #{input_source => 4194304, input_content => 2097152,
                output_source => 4194304, output_content => 65536,
                keys => [<<"secret">>, <<"token">>, <<"password">>, <<"auth">>,
                         <<"cookie">>, <<"credential">>, <<"api_key">>, <<"apikey">>],
                literals => []}}.

with_limits({options, O}, S, C)
  when is_integer(S), S > 0, S =< 4194304,
       is_integer(C), C > 0, C =< 2097152 ->
    {ok, {options, O#{input_source := S, input_content := C,
                      output_source := S, output_content := C}}};
with_limits(_, _, _) -> {error, invalid_limits}.

with_direction_limits({options, O}, {input_limits, S, C}) ->
    direction_limits(O, input, S, C);
with_direction_limits({options, O}, {output_limits, S, C}) ->
    direction_limits(O, output, S, C);
with_direction_limits(_, _) -> {error, invalid_limits}.

direction_limits(O, Direction, S, C)
  when is_integer(S), S > 0, S =< 4194304,
       is_integer(C), C > 0, C =< 2097152 ->
    Source = case Direction of input -> input_source; output -> output_source end,
    Content = case Direction of input -> input_content; output -> output_content end,
    {ok, {options, O#{Source := S, Content := C}}};
direction_limits(_, _, _, _) -> {error, invalid_limits}.

with_redacted_keys({options, O}, Rules) -> rules(O, keys, Rules, 128).
with_redacted_text({options, O}, Rules) -> rules(O, literals, Rules, 256).

rules(O, Kind, Rules, Max) ->
    try
        ensure(length(Rules) =< 32, too_many_rules),
        lists:foreach(fun(R) ->
            ensure(is_binary(R) andalso byte_size(R) > 0 andalso
                   byte_size(R) =< Max, invalid_rule),
            ensure(is_binary(unicode:characters_to_binary(R)), invalid_rule)
        end, Rules),
        Normal = case Kind of
            keys -> [binary:copy(lower(R)) || R <- Rules];
            literals -> [binary:copy(R) || R <- Rules]
        end,
        lists:foreach(fun(R) -> ensure(byte_size(R) =< Max, invalid_rule) end, Normal),
        Combined = lists:usort(maps:get(Kind, O) ++ Normal),
        Limit = case Kind of keys -> 40; literals -> 32 end,
        ensure(length(Combined) =< Limit, too_many_rules),
        {ok, {options, O#{Kind := Combined}}}
    catch throw:R -> {error, R}; _:_ -> {error, invalid_rule} end.

input({options, O}, Api, Body) -> capture(directional(O, input), Api, Body, input).
buffered({options, O}, Api, Body) -> capture(directional(O, output), Api, Body, output).
incomplete() -> omitted(<<"incomplete">>).

directional(O, input) -> O#{source => maps:get(input_source, O), content => maps:get(input_content, O)};
directional(O, output) -> O#{source => maps:get(output_source, O), content => maps:get(output_content, O)}.

%% Normalized values are traversed and budgeted before a projection tree is
%% assembled. Provider schemas, descriptions, thinking and metadata never enter it.
normalized_input({options, O0}, System, Messages, Tools) ->
    O = directional(O0, input),
    safe_capture(fun() ->
        bounded_list(Messages, 64), bounded_list(Tools, 32),
        Source = normalized_input_cost(System, Messages, Tools, O),
        ensure(Source =< maps:get(source, O), source_limit),
        {Projected, Filtered} = normalized_messages(O, Messages),
        {Instructions, IF} = case System of
            none -> {[], false};
            {some, B} -> {P, F} = text(O, B), {[{<<"gen_ai.system_instructions">>, [P]}], F};
            _ -> throw(unsupported_shape)
        end,
        {Defs, DF} = normalized_tools(O, Tools),
        Attrs = [{<<"gen_ai.input.messages">>, Projected}] ++ Instructions ++ Defs,
        encoded(O, input, Attrs, Filtered orelse IF orelse DF)
    end).

normalized_output({options, O0}, Message, Stop) ->
    O = directional(O0, output),
    safe_capture(fun() ->
        Reason = normalized_finish(Stop),
        Source = normalized_message_raw_cost(Message, 0, O),
        ensure(Source =< maps:get(source, O), source_limit),
        validate_normalized_message(Message),
        {Messages, Filtered} = normalized_messages(O, [Message]),
        [Assistant] = Messages,
        ensure(maps:get(<<"role">>, Assistant) =:= <<"assistant">>, unsupported_shape),
        Output = [Assistant#{<<"finish_reason">> => Reason}],
        encoded(O, output, [{<<"gen_ai.output.messages">>, Output}], Filtered)
    end).

normalized_finish({some, stop}) -> <<"stop">>;
normalized_finish({some, length}) -> <<"length">>;
normalized_finish({some, tool_use}) -> <<"tool_call">>;
normalized_finish({some, error}) -> throw(incomplete);
normalized_finish(_) -> throw(incomplete).

normalized_input_cost(System, Messages, Tools, O) ->
    S = case System of none -> 0; {some, B} -> raw_string_cost(0, B, O); _ -> throw(unsupported_shape) end,
    MessageBytes = lists:foldl(fun(M, N) -> normalized_message_raw_cost(M, N, O) end, S, Messages),
    ToolBytes = lists:foldl(fun(T, Acc) ->
        Name = case T of {tool_definition, ToolName, _, _} -> ToolName; _ -> throw(unsupported_shape) end,
        raw_string_cost(Acc, Name, O)
    end, MessageBytes, Tools),
    validate_normalized_input(System, Messages, Tools),
    ToolBytes.

raw_string_cost(N, B, O) when is_binary(B) ->
    debit_source(N, byte_size(B), O);
raw_string_cost(_, _, _) -> throw(unsupported_shape).

debit_source(N, Add, O) ->
    Total = N + Add,
    ensure(Total =< maps:get(source, O), source_limit),
    Total.

validate_string(B) when is_binary(B) ->
    ensure(is_binary(unicode:characters_to_binary(B)), invalid_utf8);
validate_string(_) -> throw(unsupported_shape).

validate_normalized_input(System, Messages, Tools) ->
    case System of none -> ok; {some, B} -> validate_string(B); _ -> throw(unsupported_shape) end,
    lists:foreach(fun validate_normalized_message/1, Messages),
    lists:foreach(fun
        ({tool_definition, Name, _, _}) -> validate_string(Name);
        (_) -> throw(unsupported_shape)
    end, Tools).

validate_normalized_message({user, B}) -> validate_string(B);
validate_normalized_message({developer, B}) -> validate_string(B);
validate_normalized_message({system, B}) -> validate_string(B);
validate_normalized_message({tool, Id, B}) -> validate_string(Id), validate_string(B);
validate_normalized_message({assistant, B, Calls, _, _}) ->
    validate_string(B),
    lists:foreach(fun
        ({tool_call, Id, Name, Args}) -> validate_string(Id), validate_string(Name), validate_string(Args);
        (_) -> throw(unsupported_shape)
    end, Calls);
validate_normalized_message(_) -> throw(unsupported_shape).

normalized_message_raw_cost({user, B}, N, O) -> raw_string_cost(N, B, O);
normalized_message_raw_cost({developer, B}, N, O) -> raw_string_cost(N, B, O);
normalized_message_raw_cost({system, B}, N, O) -> raw_string_cost(N, B, O);
normalized_message_raw_cost({tool, Id, B}, N, O) -> raw_string_cost(raw_string_cost(N, Id, O), B, O);
normalized_message_raw_cost({assistant, B, Calls, _, _}, N, O) ->
    bounded_list(Calls, 32),
    lists:foldl(fun(C, Acc) ->
        case C of
            {tool_call, Id, Name, Args} ->
                raw_string_cost(raw_string_cost(raw_string_cost(Acc, Id, O), Name, O), Args, O);
            _ -> throw(unsupported_shape)
        end
    end, raw_string_cost(N, B, O), Calls);
normalized_message_raw_cost(_, _, _) -> throw(unsupported_shape).

normalized_messages(O, Messages) -> map_filtered(fun(M) -> normalized_message(O, M) end, Messages).
normalized_message(O, {user, B}) -> normalized_text_message(O, <<"user">>, B);
normalized_message(O, {developer, B}) -> normalized_text_message(O, <<"developer">>, B);
normalized_message(O, {system, B}) -> normalized_text_message(O, <<"system">>, B);
normalized_message(O, {tool, Id, B}) ->
    {P, F} = tool_result(O, Id, B), {message(<<"tool">>, [P]), F};
normalized_message(O, {assistant, B, Calls, _, _}) ->
    {TextParts, TF} = case B of
        <<>> -> {[], false};
        _ -> {TextPart, TextFiltered} = text(O, B), {[TextPart], TextFiltered}
    end,
    {CallParts, CF} = flat_filtered(fun
        ({tool_call, Id, Name, Args}) -> {P, F} = tool_call(O, Id, Name, Args), {[P], F};
        (_) -> throw(unsupported_shape)
    end, bounded_list(Calls, 32)),
    {message(<<"assistant">>, TextParts ++ CallParts), TF orelse CF};
normalized_message(_, _) -> throw(unsupported_shape).

normalized_text_message(O, Role, B) ->
    {Parts, F} = case B of <<>> -> {[], false}; _ -> {P, F0} = text(O, B), {[P], F0} end,
    {message(Role, Parts), F}.

normalized_tools(_O, []) -> {[], false};
normalized_tools(O, Tools) ->
    {Defs, F} = map_filtered(fun
        ({tool_definition, Name, _, _}) ->
            identity(O, Name), {#{<<"type">> => <<"function">>, <<"name">> => Name}, false};
        (_) -> throw(unsupported_shape)
    end, bounded_list(Tools, 32)),
    {[{<<"gen_ai.tool.definitions">>, Defs}], F}.

capture(O, Api, Body, Direction) ->
    safe_capture(fun() ->
        Value = parse(Body, maps:get(source, O)),
        ensure(is_map(Value), unsupported_shape),
        ensure(maps:get(<<"error">>, Value, null) =:= null, incomplete),
        {Attrs, Filtered} = project(O, Api, Value, Direction),
        encoded(O, Direction, Attrs, Filtered)
    end).

safe_capture(F) ->
    try F()
    catch throw:R -> omitted(reason(R)); _:_ -> omitted(<<"invalid_json">>) end.

reason(source_limit) -> <<"source_limit">>;
reason(content_limit) -> <<"content_limit">>;
reason(structure_limit) -> <<"structure_limit">>;
reason(invalid_utf8) -> <<"invalid_utf8">>;
reason(unsupported_shape) -> <<"unsupported_shape">>;
reason(incomplete) -> <<"incomplete">>;
reason(redaction) -> <<"redaction">>;
reason(_) -> <<"invalid_json">>.

omitted(Reason) -> {capture, #{status => <<"omitted">>, reason => Reason, attrs => []}}.

pairs({capture, C}, Direction) ->
    Prefix = case Direction of input -> <<"pig.content.input.">>;
                               output -> <<"pig.content.output.">> end,
    ensure_direction(C, Direction, Prefix).

ensure_direction(#{direction := Other}, Direction, Prefix) when Other =/= Direction ->
    [{<<Prefix/binary, "status">>, <<"omitted">>},
     {<<Prefix/binary, "reason">>, <<"unsupported_shape">>}];
ensure_direction(C, _Direction, Prefix) ->
    Attrs = maps:get(attrs, C),
    [{<<Prefix/binary, "status">>, maps:get(status, C)},
     {<<Prefix/binary, "reason">>, maps:get(reason, C)} | Attrs].

encoded(O, Direction, Attrs, Filtered) ->
    lists:foreach(fun({_K, V}) -> projection_limits(V) end, Attrs),
    %% This is a final serialized-JSON budget, not an in-flight heap budget.
    %% Account for escaping before allocating the final serialized attributes.
    lists:foldl(fun({_K, V}, Left) -> json_budget(V, Left) end, maps:get(content, O), Attrs),
    Encoded = [{K, binary:copy(iolist_to_binary(json:encode(V)))} || {K, V} <- Attrs],
    ensure(lists:sum([byte_size(V) || {_, V} <- Encoded]) =< maps:get(content, O), content_limit),
    {Status, Reason} = case Filtered of
        true -> {<<"filtered">>, <<"redacted_or_excluded">>};
        false -> {<<"captured">>, <<"complete">>}
    end,
    {capture, #{direction => Direction, status => Status, reason => Reason, attrs => Encoded}}.

ensure(true, _) -> ok;
ensure(false, R) -> throw(R).

%% Bound depth and token starts per parse, not across embedded JSON parses.
%% Strings are scanned without interpreting escapes; OTP subsequently validates
%% syntax and UTF-8. The cumulative stream source cap bounds retained input.
parse(B, Max) when is_binary(B) ->
    ensure(byte_size(B) =< Max, source_limit),
    preflight(B, 0, 0, outside, false),
    ensure(is_binary(unicode:characters_to_binary(B)), invalid_utf8),
    json:decode(binary:copy(B));
parse(_, _) -> throw(unsupported_shape).

preflight(_, D, N, _, _) when D > ?MAX_DEPTH; N > ?MAX_NODES -> throw(structure_limit);
preflight(_, _, _, scalar, Length) when Length > 128 -> throw(structure_limit);
preflight(<<>>, _, _, _, _) -> ok;
preflight(<<_, Rest/binary>>, D, N, quoted, true) -> preflight(Rest, D, N, quoted, false);
preflight(<<$\\, Rest/binary>>, D, N, quoted, false) -> preflight(Rest, D, N, quoted, true);
preflight(<<$", Rest/binary>>, D, N, quoted, false) -> preflight(Rest, D, N, outside, false);
preflight(<<_, Rest/binary>>, D, N, quoted, false) -> preflight(Rest, D, N, quoted, false);
preflight(<<$", Rest/binary>>, D, N, _, _) -> preflight(Rest, D, N + 1, quoted, false);
preflight(<<C, Rest/binary>>, D, N, _, _) when C =:= ${; C =:= $[ ->
    preflight(Rest, D + 1, N + 1, outside, false);
preflight(<<C, Rest/binary>>, D, N, _, _) when C =:= $}; C =:= $] ->
    preflight(Rest, D - 1, N, outside, false);
preflight(<<C, Rest/binary>>, D, N, _, _)
  when C =:= $,; C =:= $:; C =:= 32; C =:= 9; C =:= 10; C =:= 13 ->
    preflight(Rest, D, N, outside, false);
preflight(<<_, Rest/binary>>, D, N, outside, _) -> preflight(Rest, D, N + 1, scalar, 1);
preflight(<<_, Rest/binary>>, D, N, scalar, Length) -> preflight(Rest, D, N, scalar, Length + 1).

bounded_list(L, Max) when is_list(L) ->
    bounded_list_count(L, Max, 0), L;
bounded_list(_, _) -> throw(structure_limit).

bounded_list_count([], _Max, _Count) -> ok;
bounded_list_count([_ | Rest], Max, Count) when Count < Max ->
    bounded_list_count(Rest, Max, Count + 1);
bounded_list_count(_, _Max, _Count) -> throw(structure_limit).
required(M, K) when is_map(M) ->
    case maps:find(K, M) of {ok, V} -> V; error -> throw(unsupported_shape) end;
required(_, _) -> throw(unsupported_shape).

project(O, chat_completions, V, input) ->
    {Messages, F1} = map_filtered(fun(M) -> chat_message(O, M) end,
                                bounded_list(required(V, <<"messages">>), 64)),
    {Tools, F2} = tools(O, V, chat_completions),
    {[{<<"gen_ai.input.messages">>, Messages}] ++ Tools, F1 orelse F2};
project(O, responses, V, input) ->
    {Messages, F1} = case required(V, <<"input">>) of
        Text when is_binary(Text) ->
            {Part, F} = text(O, Text), {[message(<<"user">>, [Part])], F};
        Items -> response_inputs(O, bounded_list(Items, 64))
    end,
    {Instructions, F2} = case maps:get(<<"instructions">>, V, null) of
        null -> {[], false};
        B when is_binary(B) ->
            {P, F3} = text(O, B), {[{<<"gen_ai.system_instructions">>, [P]}], F3};
        _ -> throw(unsupported_shape)
    end,
    {Tools, F4} = tools(O, V, responses),
    {[{<<"gen_ai.input.messages">>, Messages}] ++ Instructions ++ Tools, F1 orelse F2 orelse F4};
project(O, chat_completions, V, output) ->
    Choices = bounded_list(required(V, <<"choices">>), 16),
    ensure(Choices =/= [], incomplete),
    {Messages, F} = map_filtered(fun(C) ->
        Reason = finish_reason(required(C, <<"finish_reason">>)),
        {M, MF} = chat_message(O, required(C, <<"message">>)),
        ensure(maps:get(<<"role">>, M) =:= <<"assistant">>, unsupported_shape),
        {M#{<<"finish_reason">> => Reason}, MF}
    end, Choices),
    {[{<<"gen_ai.output.messages">>, Messages}], F};
project(O, responses, V, output) ->
    ensure(maps:get(<<"status">>, V, undefined) =:= <<"completed">>, incomplete),
    {Parts, F} = response_output(O, bounded_list(required(V, <<"output">>), 64)),
    Messages = case Parts of
        [] -> [];
        _ -> [#{<<"role">> => <<"assistant">>, <<"parts">> => Parts,
                <<"finish_reason">> => response_finish(Parts)}]
    end,
    {[{<<"gen_ai.output.messages">>, Messages}], F};
project(_, _, _, _) -> throw(unsupported_shape).

finish_reason(<<"stop">>) -> <<"stop">>;
finish_reason(<<"length">>) -> <<"length">>;
finish_reason(<<"content_filter">>) -> <<"content_filter">>;
finish_reason(<<"tool_calls">>) -> <<"tool_call">>;
finish_reason(<<"function_call">>) -> <<"tool_call">>;
finish_reason(_) -> throw(incomplete).

response_finish(Parts) ->
    case lists:any(fun(P) -> maps:get(<<"type">>, P) =:= <<"tool_call">> end, Parts) of
        true -> <<"tool_call">>;
        false -> <<"stop">>
    end.

message(Role, Parts) -> #{<<"role">> => Role, <<"parts">> => Parts}.
role(<<"user">>) -> <<"user">>;
role(<<"assistant">>) -> <<"assistant">>;
role(<<"system">>) -> <<"system">>;
role(<<"developer">>) -> <<"developer">>;
role(<<"tool">>) -> <<"tool">>;
role(_) -> throw(unsupported_shape).

chat_message(O, M) ->
    Role = role(required(M, <<"role">>)),
    {Parts, F1} = case Role of
        <<"tool">> ->
            {P, F} = tool_result(O, required(M, <<"tool_call_id">>), required(M, <<"content">>)),
            {[P], F};
        _ -> content_parts(O, maps:get(<<"content">>, M, null))
    end,
    {Calls, F2} = flat_filtered(fun(C) ->
        case required(C, <<"type">>) of
            <<"function">> ->
                Fn = required(C, <<"function">>),
                {CallPart, CallFiltered} = tool_call(O, required(C, <<"id">>), required(Fn, <<"name">>), required(Fn, <<"arguments">>)),
                {[CallPart], CallFiltered orelse unknown(Fn, [<<"name">>, <<"arguments">>]) orelse
                      unknown(C, [<<"type">>, <<"id">>, <<"function">>])};
            _ -> {[], true}
        end
    end, bounded_list(maps:get(<<"tool_calls">>, M, []), 32)),
    F3 = unknown(M, [<<"role">>, <<"content">>, <<"tool_calls">>, <<"tool_call_id">>,
                     <<"id">>, <<"type">>, <<"status">>]),
    {message(Role, Parts ++ Calls), F1 orelse F2 orelse F3}.

content_parts(_, null) -> {[], false};
content_parts(O, B) when is_binary(B) -> {P, F} = text(O, B), {[P], F};
content_parts(O, L) when is_list(L) ->
    flat_filtered(fun(P) ->
        case required(P, <<"type">>) of
            T when T =:= <<"text">>; T =:= <<"input_text">>; T =:= <<"output_text">> ->
                {Part, F} = text(O, required(P, <<"text">>)),
                {[Part], F orelse unknown(P, [<<"type">>, <<"text">>])};
            _ -> {[], true}
        end
    end, bounded_list(L, 256));
content_parts(_, _) -> throw(unsupported_shape).

text(O, B) when is_binary(B) ->
    {Clean, F} = redact_text(O, B),
    {#{<<"type">> => <<"text">>, <<"content">> => Clean}, F};
text(_, _) -> throw(unsupported_shape).

response_inputs(O, Items) ->
    flat_filtered(fun(I) ->
        case maps:get(<<"type">>, I, <<"message">>) of
            <<"message">> -> {M, F} = chat_message(O, I), {[M], F};
            <<"function_call">> ->
                {P, F} = response_call(O, I), {[message(<<"assistant">>, [P])], F};
            <<"function_call_output">> ->
                {P, F} = response_result(O, required(I, <<"call_id">>), required(I, <<"output">>)),
                {[message(<<"tool">>, [P])], F};
            _ -> {[], true}
        end
    end, Items).

response_output(O, Items) ->
    flat_filtered(fun(I) ->
        case required(I, <<"type">>) of
            <<"message">> ->
                ensure(maps:get(<<"status">>, I, <<"completed">>) =:= <<"completed">>, incomplete),
                ensure(required(I, <<"role">>) =:= <<"assistant">>, unsupported_shape),
                {P, F} = content_parts(O, required(I, <<"content">>)),
                {P, F orelse unknown(I, [<<"type">>, <<"role">>, <<"status">>, <<"content">>, <<"id">>])};
            <<"function_call">> ->
                ensure(maps:get(<<"status">>, I, <<"completed">>) =:= <<"completed">>, incomplete),
                {P, F} = response_call(O, I), {[P], F};
            _ -> {[], true}
        end
    end, Items).

response_call(O, I) ->
    {P, F} = tool_call(O, required(I, <<"call_id">>), required(I, <<"name">>), required(I, <<"arguments">>)),
    {P, F orelse unknown(I, [<<"type">>, <<"id">>, <<"call_id">>, <<"name">>, <<"arguments">>, <<"status">>])}.

tool_call(O, Id, Name, Arguments) ->
    identity(O, Id), identity(O, Name),
    {Args, F} = payload(O, Arguments, arguments),
    {#{<<"type">> => <<"tool_call">>, <<"id">> => Id, <<"name">> => Name,
       <<"arguments">> => Args}, F}.

%% Only native arrays are provider content parts. JSON arrays inside textual
%% tool output remain application data and still receive recursive redaction.
response_result(O, Id, Value) when is_list(Value) ->
    {Parts, Excluded} = flat_filtered(fun
        (#{<<"type">> := <<"input_text">>, <<"text">> := B} = P) ->
            ensure(is_binary(B), unsupported_shape),
            {[#{<<"type">> => <<"text">>, <<"content">> => B}],
             unknown(P, [<<"type">>, <<"text">>])};
        (_) -> {[], true}
    end, bounded_list(Value, 256)),
    {Part, Filtered} = tool_result(O, Id, Parts),
    {Part, Excluded orelse Filtered};
response_result(O, Id, Value) -> tool_result(O, Id, Value).

tool_result(O, Id, Value) ->
    identity(O, Id),
    {Clean, F} = payload(O, Value, response),
    {#{<<"type">> => <<"tool_call_response">>, <<"id">> => Id, <<"response">> => Clean}, F}.

identity(O, B) ->
    ensure(is_binary(B) andalso byte_size(B) > 0 andalso byte_size(B) =< 256, redaction),
    ensure(not lists:any(fun(L) -> binary:match(B, L) =/= nomatch end, maps:get(literals, O)), redaction),
    ensure(binary:match(B, <<"://">>) =:= nomatch, redaction).

tools(O, V, Api) ->
    case maps:find(<<"tools">>, V) of
        error -> {[], false};
        {ok, L} ->
            {Defs, F} = flat_filtered(fun(T) ->
                case required(T, <<"type">>) of
                    <<"function">> ->
                        Fn = case Api of chat_completions -> required(T, <<"function">>); responses -> T end,
                        Name = required(Fn, <<"name">>), identity(O, Name),
                        {[#{<<"type">> => <<"function">>, <<"name">> => Name}],
                         unknown(Fn, [<<"type">>, <<"name">>])};
                    _ -> {[], true}
                end
            end, bounded_list(L, 32)),
            {[{<<"gen_ai.tool.definitions">>, Defs}], F}
    end.

unknown(M, Keys) -> maps:size(maps:without(Keys, M)) > 0.
map_filtered(Fun, L) ->
    {Rev, F} = lists:foldl(fun(X, {Acc, Flag}) ->
        {Y, FY} = Fun(X), {[Y | Acc], Flag orelse FY}
    end, {[], false}, L),
    {lists:reverse(Rev), F}.
flat_filtered(Fun, L) ->
    {Lists, F} = map_filtered(Fun, L), {lists:append(Lists), F}.

lower(B) -> unicode:characters_to_binary(string:casefold(unicode:characters_to_list(B))).
redact_text(O, B) ->
    case maps:get(literals, O) of
        [] -> {B, false};
        Rules ->
            case binary:match(B, Rules) of
                nomatch -> {B, false};
                _ ->
                    %% Match the original once; never redact our own replacement.
                    Replaced = binary:replace(B, Rules, ?REDACTED, [global]),
                    ensure(byte_size(Replaced) =< maps:get(content, O), content_limit),
                    {Replaced, true}
            end
    end.

payload(O, B, arguments) when is_binary(B) ->
    redact_value(O, parse(B, maps:get(source, O)), 0);
payload(O, B, response) when is_binary(B) ->
    %% Plain textual tool output is supported, but JSON-looking malformed output
    %% is never used as a raw fallback around recursive redaction.
    case json_looking(B) of
        true -> redact_value(O, parse(B, maps:get(source, O)), 0);
        false -> redact_text(O, B)
    end;
payload(O, V, _) -> redact_value(O, V, 0).

json_looking(B) ->
    case string:trim(B, leading) of
        <<C, _/binary>> when C =:= ${; C =:= $[; C =:= $" -> true;
        _ -> false
    end.

redact_value(_, _, D) when D > ?MAX_DEPTH -> throw(structure_limit);
redact_value(O, M, D) when is_map(M) ->
    {Pairs, F} = map_filtered(fun({K, V}) ->
        LowerKey = lower(K),
        Sensitive = lists:any(fun(R) -> binary:match(LowerKey, R) =/= nomatch end, maps:get(keys, O)),
        {Key, KF} = redact_text(O, K),
        case Sensitive of
            true -> {{Key, ?REDACTED}, true};
            false -> {Clean, VF} = redact_value(O, V, D + 1), {{Key, Clean}, KF orelse VF}
        end
    end, maps:to_list(M)),
    {maps:from_list(Pairs), F};
redact_value(O, L, D) when is_list(L) ->
    map_filtered(fun(V) -> redact_value(O, V, D + 1) end, L);
redact_value(O, B, D) when is_binary(B) ->
    case json_looking(B) of
        true ->
            {Clean, F} = redact_value(O, parse(B, maps:get(source, O)), D + 1),
            %% Keep JSON-in-string shape while still recursively sanitizing it.
            json_budget(Clean, maps:get(content, O)),
            {iolist_to_binary(json:encode(Clean)), F};
        false -> redact_text(O, B)
    end;
redact_value(_, V, _) -> {V, false}.

json_budget(_, Left) when Left < 0 -> throw(content_limit);
json_budget(B, Left) when is_binary(B) -> string_budget(B, Left - 2);
json_budget(L, Left) when is_list(L) ->
    lists:foldl(fun(V, N) -> json_budget(V, N) end,
                debit(Left, 2 + erlang:max(0, length(L) - 1)), L);
json_budget(M, Left) when is_map(M) ->
    lists:foldl(fun({K, V}, N) -> json_budget(V, json_budget(K, N) - 1) end,
                debit(Left, 2 + erlang:max(0, map_size(M) - 1)), maps:to_list(M));
json_budget(V, Left) -> debit(Left, iolist_size(json:encode(V))).

string_budget(_, Left) when Left < 0 -> throw(content_limit);
string_budget(<<>>, Left) -> Left;
string_budget(<<C, Rest/binary>>, Left) when C =:= $"; C =:= $\\ ->
    string_budget(Rest, Left - 2);
string_budget(<<C, Rest/binary>>, Left) when C =:= 8; C =:= 9; C =:= 10; C =:= 12; C =:= 13 ->
    string_budget(Rest, Left - 2);
string_budget(<<C, Rest/binary>>, Left) when C < 32 -> string_budget(Rest, Left - 6);
string_budget(<<_, Rest/binary>>, Left) -> string_budget(Rest, Left - 1).

debit(Left, N) -> ensure(Left >= N, content_limit), Left - N.

projection_limits(L) ->
    bounded_list(L, 64),
    Parts = lists:sum([length(maps:get(<<"parts">>, M, [])) || M <- L]),
    ensure(Parts =< 256, structure_limit).

%% SSE framing and provider accumulators are intentionally separate from the
%% protocol codecs: those codecs discard candidate boundaries and item linkage.
new_stream({options, O}, Api) ->
    #{options => directional(O, output), api => Api, seen => 0, line => [], data => [],
      choices => #{}, items => #{}, terminal => false, filtered => false, skip_lf => false}.

push(#{failure := _} = S, _) -> S;
push(S, Chunk) ->
    try
        Seen = maps:get(seen, S) + byte_size(Chunk),
        ensure(Seen =< maps:get(source, maps:get(options, S)), source_limit),
        frame(Chunk, S#{seen := Seen})
    catch throw:R -> failed(S, reason(R)); _:_ -> failed(S, <<"invalid_json">>) end.

%% Keep an unfinished line as detached fragments rather than repeatedly copying
%% a growing prefix. CR, LF and split CRLF each represent one line ending.
frame(<<>>, S) -> S;
frame(<<10, Rest/binary>>, #{skip_lf := true} = S) -> frame(Rest, S#{skip_lf := false});
frame(B, S0) ->
    S = S0#{skip_lf := false},
    case binary:match(B, [<<13>>, <<10>>]) of
        nomatch -> S#{line := [binary:copy(B) | maps:get(line, S)]};
        {N, 1} ->
            <<Segment:N/binary, Delimiter, Rest/binary>> = B,
            Line = fragments([Segment | maps:get(line, S)]),
            Next = check_state(sse_line(Line, S#{line := [], skip_lf := Delimiter =:= 13})),
            frame(Rest, Next)
    end.

failed(S, Reason) -> #{options => maps:get(options, S), api => maps:get(api, S), failure => Reason}.

check_state(S) ->
    ChatParts = lists:sum([1 + map_size(maps:get(tools, C)) || C <- maps:values(maps:get(choices, S))]),
    ResponseParts = lists:sum([case maps:get(kind, I) of
        message -> map_size(maps:get(parts, I));
        _ -> 1
    end || I <- maps:values(maps:get(items, S))]),
    ensure(ChatParts + ResponseParts =< 256, structure_limit),
    S.

sse_line(Line0, S) ->
    Line = case Line0 of
        <<>> -> <<>>;
        _ -> case binary:last(Line0) of
            13 -> binary:part(Line0, 0, byte_size(Line0) - 1);
            _ -> Line0
        end
    end,
    case Line of
        <<>> -> dispatch(S);
        <<"data:", $ , Data/binary>> -> S#{data := [binary:copy(Data) | maps:get(data, S)]};
        <<"data:", Data/binary>> -> S#{data := [binary:copy(Data) | maps:get(data, S)]};
        _ -> S
    end.

dispatch(#{data := []} = S) -> S;
dispatch(S) ->
    Data = iolist_to_binary(lists:join(<<"\n">>, lists:reverse(maps:get(data, S)))),
    Next = S#{data := []},
    case Data of
        <<"[DONE]">> ->
            ensure(maps:get(api, S) =:= chat_completions, unsupported_shape),
            Next#{terminal := true};
        _ ->
            V = parse(Data, maps:get(source, maps:get(options, S))),
            ensure(is_map(V), unsupported_shape),
            ensure(not maps:is_key(<<"error">>, V), incomplete),
            case maps:get(api, S) of
                chat_completions -> chat_event(Next, V);
                responses -> response_event(Next, V);
                _ -> throw(unsupported_shape)
            end
    end.

index(V) -> ensure(is_integer(V) andalso V >= 0 andalso V < 256, structure_limit), V.

chat_event(S, V) ->
    Cs = bounded_list(required(V, <<"choices">>), 16),
    lists:foldl(fun(C, Acc) ->
        ensure(not maps:get(terminal, Acc), incomplete),
        I = index(required(C, <<"index">>)),
        All = maps:get(choices, Acc),
        Old = maps:get(I, All, #{text => [], tools => #{}, role => <<"assistant">>, finish => null}),
        ensure(maps:get(finish, Old) =:= null, incomplete),
        D = maps:get(<<"delta">>, C, #{}),
        ensure(is_map(D), unsupported_shape),
        R = maps:get(<<"role">>, D, maps:get(role, Old)),
        ensure(R =:= <<"assistant">>, unsupported_shape),
        Text = case maps:get(<<"content">>, D, null) of
            null -> maps:get(text, Old);
            B when is_binary(B) -> [binary:copy(B) | maps:get(text, Old)];
            _ -> throw(unsupported_shape)
        end,
        Tools = lists:foldl(fun chat_tool_delta/2, maps:get(tools, Old),
                           bounded_list(maps:get(<<"tool_calls">>, D, []), 32)),
        Finish = maps:get(<<"finish_reason">>, C, null),
        case Finish of null -> ok; _ -> finish_reason(Finish) end,
        New = Old#{text := Text, tools := Tools, role := <<"assistant">>, finish := Finish},
        Updated = All#{I => New},
        ensure(map_size(Updated) =< 16, structure_limit),
        Acc#{choices := Updated, filtered := maps:get(filtered, Acc) orelse
             unknown(D, [<<"role">>, <<"content">>, <<"tool_calls">>])}
    end, S, Cs).

chat_tool_delta(D, Tools) ->
    I = index(required(D, <<"index">>)),
    T = maps:get(I, Tools, #{args => [], id => undefined, name => undefined}),
    Fn = maps:get(<<"function">>, D, #{}),
    Type = maps:get(<<"type">>, D, <<"function">>),
    ensure(Type =:= <<"function">>, unsupported_shape),
    Args = case maps:get(<<"arguments">>, Fn, undefined) of
        undefined -> maps:get(args, T);
        B when is_binary(B) -> [binary:copy(B) | maps:get(args, T)];
        _ -> throw(unsupported_shape)
    end,
    New = T#{args := Args, id := chat_identity(maps:get(id, T), maps:get(<<"id">>, D, undefined)),
             name := chat_identity(maps:get(name, T), maps:get(<<"name">>, Fn, undefined))},
    Updated = Tools#{I => New},
    ensure(map_size(Updated) =< 32, structure_limit), Updated.

%% Match the Chat codec: accept fragments, repeated values and cumulative
%% prefixes. Bound every merge; tool_call checks literals on the final identity.
chat_identity(Old, undefined) -> Old;
chat_identity(undefined, New) -> chat_identity(<<>>, New);
chat_identity(Old, New) when is_binary(New) ->
    ensure(byte_size(New) =< 256, redaction),
    case binary:longest_common_prefix([Old, New]) of
        N when N =:= byte_size(New) -> Old;
        N when N =:= byte_size(Old) -> binary:copy(New);
        _ ->
            ensure(byte_size(Old) + byte_size(New) =< 256, redaction),
            <<Old/binary, New/binary>>
    end;
chat_identity(_, _) -> throw(unsupported_shape).

stable(Old, undefined) -> Old;
stable(undefined, New) when is_binary(New) -> binary:copy(New);
stable(Same, Same) -> Same;
stable(_, _) -> throw(unsupported_shape).

response_event(S, V) ->
    Type = required(V, <<"type">>),
    case Type of
        <<"error">> -> throw(incomplete);
        <<"response.failed">> -> throw(incomplete);
        <<"response.incomplete">> -> throw(incomplete);
        <<"response.cancelled">> -> throw(incomplete);
        <<"response.canceled">> -> throw(incomplete);
        <<"response.completed">> -> response_completed(S, required(V, <<"response">>));
        <<"response.output_item.added">> -> put_item(S, V, false);
        <<"response.output_item.done">> -> put_item(S, V, true);
        <<"response.content_part.added">> -> put_part(S, V, false);
        <<"response.content_part.done">> -> put_part(S, V, true);
        <<"response.output_text.delta">> -> text_delta(S, V, false);
        <<"response.output_text.done">> -> text_delta(S, V, true);
        <<"response.function_call_arguments.delta">> -> args_delta(S, V, false);
        <<"response.function_call_arguments.done">> -> args_delta(S, V, true);
        <<"response.created">> -> ensure(not maps:get(terminal, S), incomplete), S;
        <<"response.in_progress">> -> ensure(not maps:get(terminal, S), incomplete), S;
        _ -> S#{filtered := true}
    end.

put_item(S, V, Done) ->
    ensure(not maps:get(terminal, S), incomplete),
    I = index(required(V, <<"output_index">>)),
    Item = required(V, <<"item">>),
    All = maps:get(items, S),
    Old = maps:get(I, All, undefined),
    New = item_state(Item, Done),
    case Old of
        undefined -> ok;
        _ -> stable(maps:get(id, Old, undefined), maps:get(id, New, undefined))
    end,
    Updated = All#{I => New}, ensure(map_size(Updated) =< 64, structure_limit),
    S#{items := Updated, filtered := maps:get(filtered, S) orelse maps:get(filtered, New)}.

item_state(Item, Done) ->
    case Done of
        true -> ensure(maps:get(<<"status">>, Item, <<"completed">>) =:= <<"completed">>, incomplete);
        false -> ok
    end,
    Id = copy_identity(maps:get(<<"id">>, Item, undefined)),
    Base = #{id => Id, done => Done, filtered => false},
    case required(Item, <<"type">>) of
        <<"message">> ->
            ensure(required(Item, <<"role">>) =:= <<"assistant">>, unsupported_shape),
            Parts = bounded_list(maps:get(<<"content">>, Item, []), 256),
            {_, Pairs} = lists:foldl(fun(P, {I, A}) -> {I + 1, [{I, part_state(P)} | A]} end, {0, []}, Parts),
            Base#{kind => message, parts => maps:from_list(Pairs),
                  filtered := unknown(Item, [<<"type">>, <<"role">>, <<"id">>, <<"status">>, <<"content">>])};
        <<"function_call">> ->
            Args = maps:get(<<"arguments">>, Item, <<>>), ensure(is_binary(Args), unsupported_shape),
            Base#{kind => call, call_id => copy_identity(required(Item, <<"call_id">>)),
                  name => copy_identity(required(Item, <<"name">>)), args => [binary:copy(Args)]};
        _ -> Base#{kind => excluded, filtered := true}
    end.

copy_identity(undefined) -> undefined;
copy_identity(B) when is_binary(B), byte_size(B) =< 256 -> binary:copy(B);
copy_identity(_) -> throw(unsupported_shape).

part_state(P) ->
    case required(P, <<"type">>) of
        <<"output_text">> ->
            Text = required(P, <<"text">>), ensure(is_binary(Text), unsupported_shape),
            #{kind => text, text => [binary:copy(Text)], filtered => unknown(P, [<<"type">>, <<"text">>])};
        _ -> #{kind => excluded, filtered => true}
    end.

get_item(S, V) ->
    ensure(not maps:get(terminal, S), incomplete),
    I = index(required(V, <<"output_index">>)),
    Item = required(maps:get(items, S), I),
    ensure(not maps:get(done, Item), incomplete),
    stable(maps:get(id, Item), maps:get(<<"item_id">>, V, undefined)),
    {I, Item}.

set_item(S, I, Item) -> S#{items := (maps:get(items, S))#{I := Item}}.

put_part(S, V, _Done) ->
    {I, Item} = get_item(S, V),
    ensure(maps:get(kind, Item) =:= message, unsupported_shape),
    P = index(required(V, <<"content_index">>)),
    Parts = maps:get(parts, Item),
    set_item(S, I, Item#{parts := Parts#{P => part_state(required(V, <<"part">>))}}).

text_delta(S, V, Done) ->
    {I, Item} = get_item(S, V),
    ensure(maps:get(kind, Item) =:= message, unsupported_shape),
    P = index(required(V, <<"content_index">>)),
    Parts = maps:get(parts, Item),
    Old = maps:get(P, Parts, #{kind => text, text => [], filtered => false}),
    ensure(maps:get(kind, Old) =:= text, unsupported_shape),
    K = case Done of true -> <<"text">>; false -> <<"delta">> end,
    B = required(V, K), ensure(is_binary(B), unsupported_shape),
    Text = case Done of true -> [binary:copy(B)]; false -> [binary:copy(B) | maps:get(text, Old)] end,
    set_item(S, I, Item#{parts := Parts#{P => Old#{text := Text}}}).

args_delta(S, V, Done) ->
    {I, Item} = get_item(S, V),
    ensure(maps:get(kind, Item) =:= call, unsupported_shape),
    stable(maps:get(call_id, Item), maps:get(<<"call_id">>, V, undefined)),
    K = case Done of true -> <<"arguments">>; false -> <<"delta">> end,
    B = required(V, K), ensure(is_binary(B), unsupported_shape),
    Args = case Done of true -> [binary:copy(B)]; false -> [binary:copy(B) | maps:get(args, Item)] end,
    set_item(S, I, Item#{args := Args}).

response_completed(S, R) ->
    ensure(not maps:get(terminal, S), incomplete),
    ensure(required(R, <<"status">>) =:= <<"completed">>, incomplete),
    ensure(not maps:is_key(<<"error">>, R) orelse maps:get(<<"error">>, R) =:= null, incomplete),
    case maps:find(<<"output">>, R) of
        {ok, []} ->
            case map_size(maps:get(items, S)) > 0 of
                true ->
                    %% Some streaming gateways send an empty final output array
                    %% after complete output_item.done events. Preserve them.
                    S#{terminal := true};
                false -> S#{terminal := true, items := #{}}
            end;
        {ok, Items} ->
            %% A non-empty final entity is authoritative and replaces deltas.
            All = bounded_list(Items, 64),
            {_, Pairs} = lists:foldl(fun(Item, {I, Acc}) ->
                {I + 1, [{I, item_state(Item, true)} | Acc]}
            end, {0, []}, All),
            S#{terminal := true, items := maps:from_list(Pairs)};
        error ->
            ensure(map_size(maps:get(items, S)) > 0, incomplete),
            ensure(lists:all(fun(I) -> maps:get(done, I) end, maps:values(maps:get(items, S))), incomplete),
            S#{terminal := true}
    end.

finish(_S, false) -> omitted(<<"incomplete">>);
finish(#{failure := Reason}, true) -> omitted(Reason);
finish(S0, true) ->
    safe_capture(fun() ->
        %% A newline-terminated Chat sentinel is unambiguous at confirmed EOF.
        %% Do not flush arbitrary trailing data or an unfinished sentinel line.
        S = case S0 of
            #{api := chat_completions, line := [], data := [<<"[DONE]">>]} -> dispatch(S0);
            _ -> S0
        end,
        ensure(maps:get(line, S) =:= [] andalso maps:get(data, S) =:= [], incomplete),
        {Value, Filtered} = stream_value(S),
        O = maps:get(options, S),
        {Attrs, F} = project(O, maps:get(api, S), Value, output),
        encoded(O, output, Attrs, F orelse Filtered)
    end).

stream_value(#{api := chat_completions} = S) ->
    All = maps:get(choices, S), ensure(map_size(All) > 0, incomplete),
    Choices = [begin
        ensure(maps:get(finish, C) =/= null, incomplete),
        Tools = [#{<<"id">> => maps:get(id, T), <<"type">> => <<"function">>,
                   <<"function">> => #{<<"name">> => maps:get(name, T),
                                       <<"arguments">> => fragments(maps:get(args, T))}}
                 || {_, T} <- lists:sort(maps:to_list(maps:get(tools, C)))],
        #{<<"finish_reason">> => maps:get(finish, C),
          <<"message">> => #{<<"role">> => maps:get(role, C),
                             <<"content">> => case maps:get(text, C) of
                                 [] -> null;
                                 Fragments -> fragments(Fragments)
                             end, <<"tool_calls">> => Tools}}
    end || {_, C} <- lists:sort(maps:to_list(All))],
    {#{<<"choices">> => Choices}, maps:get(filtered, S)};
stream_value(#{api := responses} = S) ->
    ensure(maps:get(terminal, S), incomplete),
    {Items, F} = map_filtered(fun({_I, Item}) -> materialize_item(Item) end,
                             lists:sort(maps:to_list(maps:get(items, S)))),
    {#{<<"status">> => <<"completed">>, <<"output">> => Items}, F orelse maps:get(filtered, S)};
stream_value(_) -> throw(unsupported_shape).

materialize_item(#{kind := message} = I) ->
    ensure(maps:get(done, I), incomplete),
    {Parts, F} = flat_filtered(fun({_N, P}) ->
        case maps:get(kind, P) of
            text -> {[#{<<"type">> => <<"output_text">>, <<"text">> => fragments(maps:get(text, P))}], maps:get(filtered, P)};
            excluded -> {[], true}
        end
    end, lists:sort(maps:to_list(maps:get(parts, I)))),
    {#{<<"type">> => <<"message">>, <<"role">> => <<"assistant">>, <<"content">> => Parts}, F orelse maps:get(filtered, I)};
materialize_item(#{kind := call} = I) ->
    ensure(maps:get(done, I), incomplete),
    {#{<<"type">> => <<"function_call">>, <<"call_id">> => maps:get(call_id, I),
       <<"name">> => maps:get(name, I), <<"arguments">> => fragments(maps:get(args, I))}, maps:get(filtered, I)};
materialize_item(_) -> {#{<<"type">> => <<"excluded">>}, true}.

fragments(Rev) -> iolist_to_binary(lists:reverse(Rev)).

retained_bytes(#{failure := _}) -> 0;
retained_bytes(S) -> binary_bytes(maps:with([line, data, choices, items], S)).
binary_bytes(B) when is_binary(B) -> byte_size(B);
binary_bytes(M) when is_map(M) -> lists:sum([binary_bytes(V) || V <- maps:values(M)]);
binary_bytes(L) when is_list(L) -> lists:sum([binary_bytes(V) || V <- L]);
binary_bytes(_) -> 0.
