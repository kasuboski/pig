-module(pig_proxy_identity_owner_test_ffi).
-export([with_upstream_propagator/1]).

%% Exercise the official upstream propagator implementation, but install it
%% only for this test and restore the caller's configured propagator afterward.
with_upstream_propagator(Work) ->
    Injector = opentelemetry:get_text_map_injector(),
    Extractor = opentelemetry:get_text_map_extractor(),
    opentelemetry:set_text_map_propagator(
        otel_propagator_text_map_composite:create([trace_context, baggage])
    ),
    try Work()
    after
        opentelemetry:set_text_map_injector(Injector),
        opentelemetry:set_text_map_extractor(Extractor)
    end.
