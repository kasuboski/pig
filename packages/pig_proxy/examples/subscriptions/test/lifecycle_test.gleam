import gleam/list
import gleeunit/should
import subscriptions/lifecycle

fn check_names(names: List(String)) -> List(String) {
  lifecycle.otel_override_names(names)
}

pub fn selects_only_exact_sdk_override_namespace_test() {
  list.each(
    [
      #([], []),
      #(["OTEL_SDK_DISABLED", "OTEL_EXPORTER_OTLP_HEADERS"], [
        "OTEL_SDK_DISABLED", "OTEL_EXPORTER_OTLP_HEADERS",
      ]),
      #(["HOME", "LATITUDE_API_KEY", "otel_disabled", "OTEL", "OTELL_KEY"], []),
      #(["HOME", "OTEL_TRACES_EXPORTER", "PIG_PROXY_PORT"], [
        "OTEL_TRACES_EXPORTER",
      ]),
    ],
    fn(scenario) { should.equal(check_names(scenario.0), scenario.1) },
  )
}

fn check_stop(
  outcome: lifecycle.SdkStopOutcome,
) -> Result(Nil, lifecycle.ShutdownError) {
  lifecycle.sdk_stop_result(outcome)
}

pub fn sdk_stop_requires_an_explicit_successful_result_test() {
  list.each(
    [
      #(lifecycle.Completed(Ok(Nil)), Ok(Nil)),
      #(lifecycle.Completed(Error(Nil)), Error(lifecycle.SdkStopFailed)),
      #(lifecycle.WorkerExited, Error(lifecycle.SdkStopFailed)),
    ],
    fn(scenario) { should.equal(check_stop(scenario.0), scenario.1) },
  )
}
