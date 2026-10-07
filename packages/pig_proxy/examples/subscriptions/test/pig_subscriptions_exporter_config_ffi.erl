-module(pig_subscriptions_exporter_config_ffi).
-export([check/0]).

check() ->
    add_sdk_paths(),
    Keys = [span_processor, processors, traces_exporter,
            bsp_exporting_timeout_ms, ssp_exporting_timeout_ms],
    Original = [{Key, application:get_env(opentelemetry, Key)} || Key <- Keys],
    OriginalOtelEnvironment = otel_environment(),
    try
        clear_otel_environment(),
        pipeline_preserved() andalso
        legacy_precedence_preserved() andalso
        defaults_only_when_unconfigured() andalso
        non_otlp_exporters_preserved() andalso
        mixed_processors_use_bounded_effective_exporter() andalso
        mixed_same_class_timeouts_are_preserved() andalso
        custom_global_exporter_is_preserved() andalso
        os_otlp_exporter_is_bounded() andalso
        sdk_disabled_and_none_are_preserved() andalso
        sdk_timeout_overrides_are_effective() andalso
        timeout_options_are_preserved()
    after
        [restore(Key, Value) || {Key, Value} <- Original],
        restore_otel_environment(OriginalOtelEnvironment)
    end.

pipeline_preserved() ->
    reset_config(),
    Batch = {otel_batch_processor,
             #{max_queue_size => 77,
               scheduled_delay_ms => 1234,
               exporter => {opentelemetry_exporter, #{httpc_options => [inet6]}}}},
    application:set_env(opentelemetry, processors,
                       [Batch, {otel_simple_processor,
                               #{exporter => {custom_exporter, #{custom => true}}}}]),
    application:unset_env(opentelemetry, span_processor),
    application:unset_env(opentelemetry, traces_exporter),
    pig_subscriptions_host_ffi:configure_bounded_otlp_exporter(),
    [{otel_batch_processor, BatchOptions},
     {otel_simple_processor, #{exporter := {custom_exporter, #{custom := true}}}}] =
        application:get_env(opentelemetry, processors, []),
    #{max_queue_size := 77, scheduled_delay_ms := 1234,
      exporting_timeout_ms := 300000,
      exporter := {pig_subscriptions_bounded_otlp_exporter,
                   #{httpc_options := [inet6]}}} = BatchOptions,
    Effective = otel_configuration:merge_with_os(application:get_all_env(opentelemetry)),
    [{otel_batch_processor, #{exporter := {pig_subscriptions_bounded_otlp_exporter,
                                           #{httpc_options := [inet6]}}}},
     {otel_simple_processor, #{exporter := {custom_exporter, #{custom := true}}}}] =
        maps:get(processors, Effective),
    true.

legacy_precedence_preserved() ->
    reset_config(),
    Configured = {otel_batch_processor,
                  #{max_queue_size => 88,
                    exporter => {opentelemetry_exporter, #{}}}},
    Ignored = [{otel_simple_processor, #{}}],
    application:set_env(opentelemetry, span_processor, Configured),
    application:set_env(opentelemetry, processors, Ignored),
    application:unset_env(opentelemetry, traces_exporter),
    pig_subscriptions_host_ffi:configure_bounded_otlp_exporter(),
    {ok, {otel_batch_processor, Options}} =
        application:get_env(opentelemetry, span_processor),
    {ok, Ignored} = application:get_env(opentelemetry, processors),
    #{max_queue_size := 88, exporting_timeout_ms := 300000,
      exporter := {pig_subscriptions_bounded_otlp_exporter, #{}}} = Options,
    true.

defaults_only_when_unconfigured() ->
    reset_config(),
    application:unset_env(opentelemetry, span_processor),
    application:unset_env(opentelemetry, processors),
    application:unset_env(opentelemetry, traces_exporter),
    pig_subscriptions_host_ffi:configure_bounded_otlp_exporter(),
    {ok, {otel_batch_processor, #{exporting_timeout_ms := 300000,
                                  exporter := {pig_subscriptions_bounded_otlp_exporter, #{}}}}} =
        application:get_env(opentelemetry, span_processor),
    true.

non_otlp_exporters_preserved() ->
    reset_config(),
    Custom = {custom_exporter, #{token => kept}},
    application:set_env(opentelemetry, processors,
                        [{otel_batch_processor, #{exporting_timeout_ms => 1234,
                                                  exporter => Custom}}]),
    application:unset_env(opentelemetry, span_processor),
    application:unset_env(opentelemetry, traces_exporter),
    pig_subscriptions_host_ffi:configure_bounded_otlp_exporter(),
    {ok, [{otel_batch_processor, #{exporting_timeout_ms := 1234,
                                   exporter := Custom}}]} =
        application:get_env(opentelemetry, processors),
    Effective = otel_configuration:merge_with_os(application:get_all_env(opentelemetry)),
    [{otel_batch_processor, #{exporting_timeout_ms := 1234, exporter := Custom}}] =
        maps:get(processors, Effective),
    undefined = application:get_env(opentelemetry, bsp_exporting_timeout_ms),
    undefined = application:get_env(opentelemetry, ssp_exporting_timeout_ms),
    true.

mixed_processors_use_bounded_effective_exporter() ->
    reset_config(),
    Custom = {custom_processor, #{anything => retained}},
    application:set_env(opentelemetry, processors,
        [{otel_batch_processor, #{exporting_timeout_ms => 2500,
                                  exporter => {opentelemetry_exporter,
                                               #{headers => [{"x", "y"}]}}}},
         {otel_batch_processor, #{exporting_timeout_ms => 1234,
                                  exporter => {custom_exporter, #{token => local}}}},
         Custom]),
    application:unset_env(opentelemetry, span_processor),
    application:set_env(opentelemetry, traces_exporter,
                        {opentelemetry_exporter, #{httpc_options => [inet6]}}),
    pig_subscriptions_host_ffi:configure_bounded_otlp_exporter(),
    {ok, {pig_subscriptions_bounded_otlp_exporter, #{httpc_options := [inet6]}}} =
        application:get_env(opentelemetry, traces_exporter),
    Effective = otel_configuration:merge_with_os(application:get_all_env(opentelemetry)),
    [{otel_batch_processor, #{exporting_timeout_ms := 300000,
                              exporter := {pig_subscriptions_bounded_otlp_exporter,
                                           #{httpc_options := [inet6]}}}},
     {otel_batch_processor, #{exporting_timeout_ms := 300000,
                              exporter := {pig_subscriptions_bounded_otlp_exporter,
                                           #{httpc_options := [inet6]}}}},
     Custom] = maps:get(processors, Effective),
    true.

mixed_same_class_timeouts_are_preserved() ->
    reset_config(),
    Custom = {custom_exporter, #{token => kept}},
    application:set_env(opentelemetry, processors,
        [{otel_batch_processor, #{exporting_timeout_ms => 1234, exporter => Custom}},
         {otel_batch_processor, #{exporting_timeout_ms => 2500,
                                  exporter => {opentelemetry_exporter, #{}}}}]),
    application:unset_env(opentelemetry, span_processor),
    application:unset_env(opentelemetry, traces_exporter),
    pig_subscriptions_host_ffi:configure_bounded_otlp_exporter(),
    Effective = otel_configuration:merge_with_os(application:get_all_env(opentelemetry)),
    [{otel_batch_processor, #{exporting_timeout_ms := 1234, exporter := Custom}},
     {otel_batch_processor, #{exporting_timeout_ms := 300000,
                              exporter := {pig_subscriptions_bounded_otlp_exporter, #{}}}}] =
        maps:get(processors, Effective),
    undefined = application:get_env(opentelemetry, bsp_exporting_timeout_ms),
    true.

custom_global_exporter_is_preserved() ->
    reset_config(),
    Custom = {custom_exporter, #{token => kept}},
    application:set_env(opentelemetry, processors,
        [{otel_batch_processor, #{exporting_timeout_ms => 1234,
                                  exporter => {opentelemetry_exporter, #{}}}},
         {custom_processor, #{custom => true}}]),
    application:unset_env(opentelemetry, span_processor),
    application:set_env(opentelemetry, traces_exporter, Custom),
    pig_subscriptions_host_ffi:configure_bounded_otlp_exporter(),
    Effective = otel_configuration:merge_with_os(application:get_all_env(opentelemetry)),
    Custom = maps:get(traces_exporter, Effective),
    [{otel_batch_processor, #{exporting_timeout_ms := 1234, exporter := Custom}},
     {custom_processor, #{custom := true}}] = maps:get(processors, Effective),
    undefined = application:get_env(opentelemetry, bsp_exporting_timeout_ms),
    undefined = application:get_env(opentelemetry, ssp_exporting_timeout_ms),
    true.

os_otlp_exporter_is_bounded() ->
    reset_config(),
    application:set_env(opentelemetry, processors,
        [{otel_batch_processor, #{max_queue_size => 79}}]),
    application:unset_env(opentelemetry, span_processor),
    os:putenv("OTEL_TRACES_EXPORTER", "otlp"),
    pig_subscriptions_host_ffi:configure_bounded_otlp_exporter(),
    false = os:getenv("OTEL_TRACES_EXPORTER"),
    {ok, {pig_subscriptions_bounded_otlp_exporter, #{}}} =
        application:get_env(opentelemetry, traces_exporter),
    Effective = otel_configuration:merge_with_os(application:get_all_env(opentelemetry)),
    [{otel_batch_processor, #{max_queue_size := 79,
                              exporting_timeout_ms := 300000,
                              exporter := {pig_subscriptions_bounded_otlp_exporter, #{}}}}] =
        maps:get(processors, Effective),
    {pig_subscriptions_bounded_otlp_exporter, #{}} = maps:get(traces_exporter, Effective),
    true.

sdk_disabled_and_none_are_preserved() ->
    reset_config(),
    application:set_env(opentelemetry, processors,
        [{otel_batch_processor, #{exporter => {custom_exporter, #{kept => true}}}}]),
    application:unset_env(opentelemetry, span_processor),
    os:putenv("OTEL_SDK_DISABLED", "true"),
    os:putenv("OTEL_TRACES_EXPORTER", "none"),
    pig_subscriptions_host_ffi:configure_bounded_otlp_exporter(),
    "true" = os:getenv("OTEL_SDK_DISABLED"),
    "none" = os:getenv("OTEL_TRACES_EXPORTER"),
    Effective = otel_configuration:merge_with_os(application:get_all_env(opentelemetry)),
    true = maps:get(sdk_disabled, Effective),
    none = maps:get(traces_exporter, Effective),
    [{otel_batch_processor, #{exporter := none}}] = maps:get(processors, Effective),
    os:unsetenv("OTEL_SDK_DISABLED"),
    os:unsetenv("OTEL_TRACES_EXPORTER"),
    true.

sdk_timeout_overrides_are_effective() ->
    reset_config(),
    application:set_env(opentelemetry, processors,
        [{otel_batch_processor, #{exporter => {opentelemetry_exporter, #{}}}},
         {otel_simple_processor, #{exporter => {opentelemetry_exporter, #{}}}}]),
    application:unset_env(opentelemetry, span_processor),
    application:unset_env(opentelemetry, traces_exporter),
    application:set_env(opentelemetry, bsp_exporting_timeout_ms, 123456),
    application:unset_env(opentelemetry, ssp_exporting_timeout_ms),
    pig_subscriptions_host_ffi:configure_bounded_otlp_exporter(),
    Effective = otel_configuration:merge_with_os(application:get_all_env(opentelemetry)),
    [{otel_batch_processor, #{exporting_timeout_ms := 123456}},
     {otel_simple_processor, #{exporting_timeout_ms := 300000}}] =
        maps:get(processors, Effective),
    undefined = application:get_env(opentelemetry, ssp_exporting_timeout_ms),
    true.

timeout_options_are_preserved() ->
    reset_config(),
    application:set_env(opentelemetry, processors,
        [{otel_batch_processor, #{exporting_timeout_ms => 600000,
                                  exporter => {opentelemetry_exporter, #{}}}},
         {otel_simple_processor, #{exporting_timeout_ms => 450000,
                                   exporter => {custom_exporter, #{custom => true}}}}]),
    application:unset_env(opentelemetry, span_processor),
    application:unset_env(opentelemetry, traces_exporter),
    pig_subscriptions_host_ffi:configure_bounded_otlp_exporter(),
    {ok, [{otel_batch_processor, #{exporting_timeout_ms := 600000}},
          {otel_simple_processor, #{exporting_timeout_ms := 450000,
                                    exporter := {custom_exporter, #{custom := true}}}}]} =
        application:get_env(opentelemetry, processors),
    undefined = application:get_env(opentelemetry, bsp_exporting_timeout_ms),
    undefined = application:get_env(opentelemetry, ssp_exporting_timeout_ms),
    true.

otel_environment() ->
    [{Name, Value} || Entry <- os:getenv(),
                      [Name, Value] <- [string:split(Entry, "=", leading)],
                      lists:prefix("OTEL_", Name)].

clear_otel_environment() ->
    [os:unsetenv(Name) || {Name, _Value} <- otel_environment()],
    ok.

restore_otel_environment(Original) ->
    Current = otel_environment(),
    [os:unsetenv(Name) || {Name, _Value} <- Current],
    [os:putenv(Name, Value) || {Name, Value} <- Original],
    ok.

reset_config() ->
    [application:unset_env(opentelemetry, Key) ||
        Key <- [span_processor, processors, traces_exporter,
                bsp_exporting_timeout_ms, ssp_exporting_timeout_ms]],
    ok.

add_sdk_paths() ->
    TestDir = filename:dirname(code:which(?MODULE)),
    ExampleDir = filename:dirname(filename:dirname(filename:dirname(
        filename:dirname(filename:dirname(TestDir))))),
    code:add_paths(filelib:wildcard(filename:join(
        [ExampleDir, "host", "_build", "default", "lib", "*", "ebin"]))),
    ok.

restore(Key, {ok, Value}) -> application:set_env(opentelemetry, Key, Value);
restore(Key, undefined) -> application:unset_env(opentelemetry, Key).
