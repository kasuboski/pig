-module(pig_otel_validation_test_ffi).
-export([check/1]).

%% Pure data cases: no SDK, processes, environment gating or network.
check(<<"duplicate_end">>) ->
    One = #{trace_id => <<"trace">>, span_id => <<"one">>},
    Two = #{trace_id => <<"trace">>, span_id => <<"two">>},
    true = pig_otel_validation_verify:unique_ids([One, Two]),
    false = pig_otel_validation_verify:unique_ids([One, One]),
    nil;
check(<<"wrong_parent">>) ->
    Parent = #{trace_id => <<"one">>, span_id => <<"parent">>},
    Good = #{trace_id => <<"one">>, parent_span_id => <<"parent">>},
    Wrong = #{trace_id => <<"two">>, parent_span_id => <<"parent">>},
    true = pig_otel_validation_verify:related(Parent, Good),
    false = pig_otel_validation_verify:related(Parent, Wrong),
    nil;
check(<<"privacy">>) ->
    Cases = [{#{attributes => #{<<"gen_ai.response.model">> => <<"fixture_model">>}}, true},
             {#{attributes => #{<<"unexpected">> => <<"PRIVATE_PROMPT">>}}, false},
             {#{events => [#{value => <<"PRIVATE_ARGUMENT">>}]}, false},
             {#{name => <<"PRIVATE_COMPLETION">>}, false}],
    lists:foreach(fun({Value, Expected}) ->
        Expected = pig_otel_validation_verify:safe_metadata(Value)
    end, Cases),
    nil;
check(<<"content_span_name_privacy">>) ->
    Base = #{scope => <<"pig_proxy">>, version => <<"0.2.0">>, schema => <<>>,
             trace_id => <<"0123456789abcdef0123456789abcdef">>,
             span_id => <<"0123456789abcdef">>, start => 1, 'end' => 1,
             status => unset, events => [], links => [],
             attributes => #{<<"pig.outcome">> => <<"succeeded">>}},
    ok = pig_otel_validation_verify:content_private_values(
        [Base#{name => <<"CAPTURE_ALLOWED_SPAN">>}]),
    rejected = try
        pig_otel_validation_verify:content_private_values(
            [Base#{name => <<"PRIVATE_SPAN_NAME">>}]),
        accepted
    catch
        error:_ -> rejected
    end,
    nil.
