import gleam/list
import pig_otel
import support/runtime_harness as check

pub fn managed_shutdown_cancels_active_traces_before_return_test() {
  list.each([pig_otel.ChatCompletions, pig_otel.Responses], fn(api) {
    check.check_stop(api, check.Managed)
  })
}

pub fn externally_managed_shutdown_leaves_cleanup_to_host_test() {
  list.each([pig_otel.ChatCompletions, pig_otel.Responses], fn(api) {
    check.check_stop(api, check.External)
  })
}
