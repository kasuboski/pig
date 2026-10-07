import gleam/list
import gleeunit/should
import subscriptions/lifecycle

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
