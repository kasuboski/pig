//// Official SDK fixture. The host alone owns processors, exporter and shutdown.

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

/// Integration tests are normally compiled, explicitly opt-in at execution.
@external(erlang, "pig_otel_validation_host", "integration_enabled")
pub fn integration_enabled() -> Bool
