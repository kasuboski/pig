import gleam/list
import gleeunit
import support/harness
import support/matrices

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn operation_matrix_test() {
  list.each(matrices.operations(), fn(row) {
    harness.check_operation(row.0, row.1, row.2, row.3)
  })
}

pub fn response_matrix_test() {
  list.each(matrices.responses(), fn(row) {
    harness.check_response(row.0, row.1)
  })
}

pub fn terminal_matrix_test() {
  list.each(matrices.terminals(), fn(row) {
    harness.check_terminal(row.0, row.1, row.2)
  })
}

pub fn header_matrix_test() {
  list.each(harness.header_fixtures(), fn(row) {
    harness.check_headers(row.0, row.1, row.2, row.3)
  })
}

pub fn disabled_has_no_lookup_and_preserves_parent_test() {
  harness.check_disabled(True)
  harness.check_disabled(False)
}

pub fn official_composite_explicit_propagation_and_privacy_test() {
  harness.check_propagation()
}

pub fn invalid_trace_context_never_forwards_stale_propagation_test() {
  harness.check_invalid_propagation()
}

pub fn lookup_failure_logs_without_fallback_or_spans_test() {
  harness.check_lookup_failure()
}

pub fn api_only_business_callbacks_and_explicit_lifecycle_test() {
  harness.check_no_sdk()
}

pub fn callback_failure_preserves_business_error_and_restores_context_test() {
  harness.check_callback_failure()
}
