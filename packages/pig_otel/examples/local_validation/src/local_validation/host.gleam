//// Official SDK fixture. The host alone owns processors, exporter and shutdown.

import gleam/erlang/process

/// Start the official simple processor, execute real consumer work, and verify
/// a deterministic ETS snapshot after consumer terminal acknowledgements.
@external(erlang, "pig_otel_validation_host", "check_recording")
pub fn check_recording(work: fn() -> Nil) -> Nil

/// Independently record the actual Pig graph without depending on proxy startup.
@external(erlang, "pig_otel_validation_host", "check_agent_recording")
pub fn check_agent_recording(work: fn() -> Nil) -> Nil

/// Independently record actual proxy buffered requests on both routes.
@external(erlang, "pig_otel_validation_host", "check_proxy_recording")
pub fn check_proxy_recording(work: fn() -> Nil) -> Nil

/// Record all four explicit-capture proxy requests using the official SDK.
@external(erlang, "pig_otel_validation_host", "check_proxy_content_recording")
pub fn check_proxy_content_recording(work: fn() -> Nil) -> Nil

/// Deliver captured proxy spans to the real local OTLP receiver and wait for ACK.
@external(erlang, "pig_otel_validation_host", "check_proxy_content_otlp")
pub fn check_proxy_content_otlp(work: fn() -> Nil) -> Nil

/// Record actual Pig direct-provider content spans using the official SDK.
@external(erlang, "pig_otel_validation_host", "check_direct_content_recording")
pub fn check_direct_content_recording(work: fn() -> Nil) -> Nil

/// Verify the actual direct-provider graph delivered to the local OTLP receiver.
@external(erlang, "pig_otel_validation_host", "check_direct_content_otlp")
pub fn check_direct_content_otlp(work: fn() -> Nil) -> Nil

/// Verify metadata-only direct runs preserve terminal fields without content.
@external(erlang, "pig_otel_validation_host", "check_direct_content_metadata")
pub fn check_direct_content_metadata(work: fn() -> Nil) -> Nil

/// Direct capture interaction remains business-compatible under Disabled policy.
@external(erlang, "pig_otel_validation_host", "check_direct_content_disabled")
pub fn check_direct_content_disabled(work: fn() -> Nil) -> Nil

/// Direct capture interaction survives absent SDK and always-off sampling.
@external(erlang, "pig_otel_validation_host", "check_direct_content_unavailable")
pub fn check_direct_content_unavailable(work: fn() -> Nil) -> Nil

/// Check real HTTP business non-interference when both capture directions overflow.
@external(erlang, "pig_otel_validation_host", "check_proxy_content_overflow")
pub fn check_proxy_content_overflow(work: fn() -> Nil) -> Nil

/// Verify real client disconnect after first body ACK and proxy root cleanup.
@external(erlang, "pig_otel_validation_host", "check_content_interrupt")
pub fn check_content_interrupt(work: fn() -> Nil) -> Nil

/// Verify malformed streamed SSE via actual HTTP, SDK and OTLP.
@external(erlang, "pig_otel_validation_host", "check_content_malformed")
pub fn check_content_malformed(work: fn() -> Nil) -> Nil

/// Verify physical retry failure and selected content via SDK and OTLP.
@external(erlang, "pig_otel_validation_host", "check_content_retry")
pub fn check_content_retry(work: fn() -> Nil) -> Nil

/// Capture-enabled business must survive absent SDK and always-off sampling.
@external(erlang, "pig_otel_validation_host", "check_content_unavailable")
pub fn check_content_unavailable(work: fn() -> Nil) -> Nil

/// Last-builder Disabled preserves business with zero exported spans.
@external(erlang, "pig_otel_validation_host", "check_content_disabled")
pub fn check_content_disabled(work: fn() -> Nil) -> Nil

/// Demonstrate SDK-side string truncation in a fresh SDK lifetime.
@external(erlang, "pig_otel_validation_host", "check_content_limits")
pub fn check_content_limits(work: fn() -> Nil) -> Nil

/// Run the compiled real proxy OTP death matrix under the official SDK.
@external(erlang, "pig_otel_validation_host", "check_stream_races")
pub fn check_stream_races() -> Nil

/// Managed runtime shutdown finishes active streams before host SDK flush.
@external(erlang, "pig_otel_validation_host", "check_runtime_shutdown")
pub fn check_runtime_shutdown() -> Nil

/// Flush the official batch processor and wait for decoded receiver delivery
/// acknowledgement before stopping the SDK.
@external(erlang, "pig_otel_validation_host", "check_otlp")
pub fn check_otlp(work: fn() -> Nil) -> Nil

/// Independently deliver actual proxy buffered requests on both routes.
@external(erlang, "pig_otel_validation_host", "check_proxy_otlp")
pub fn check_proxy_otlp(work: fn() -> Nil) -> Nil

/// Verify business output without a recording SDK, under always-off sampling,
/// and with a refused local exporter endpoint. These do not prove VM-fault safety.
@external(erlang, "pig_otel_validation_host", "check_limitations")
pub fn check_limitations(work: fn() -> Nil) -> Nil

/// Verify real provider failure status/privacy through SDK recording and OTLP.
@external(erlang, "pig_otel_validation_host", "check_failure")
pub fn check_failure(work: fn() -> Nil) -> Nil

/// Explicit Disabled policy creates zero spans while business output and
/// sanitized propagation remain unchanged under a recording SDK.
@external(erlang, "pig_otel_validation_host", "check_disabled")
pub fn check_disabled(work: fn() -> Nil) -> Nil

/// Install an official detached remote caller parent around the public agent
/// entrypoint, verifying restoration afterward. Creates no fixture span.
@external(erlang, "pig_otel_validation_host", "with_caller_parent")
pub fn with_caller_parent(streaming: Bool, work: fn() -> Nil) -> Nil

/// Confirm the real provider/tool callback sees a valid process-current span.
@external(erlang, "pig_otel_validation_host", "callback")
pub fn callback(label: String) -> Nil

/// Record context extracted from explicit request propagation headers.
@external(erlang, "pig_otel_validation_host", "propagated_context")
pub fn propagated_context(headers: List(#(String, String))) -> Nil

/// Register the proxy's host-owned root supervisor for ordered fixture teardown.
@external(erlang, "pig_otel_validation_host", "register_proxy_owners")
pub fn register_proxy_owners(pid: process.Pid) -> Nil

/// Integration tests are normally compiled, explicitly opt-in at execution.
@external(erlang, "pig_otel_validation_host", "integration_enabled")
pub fn integration_enabled() -> Bool
