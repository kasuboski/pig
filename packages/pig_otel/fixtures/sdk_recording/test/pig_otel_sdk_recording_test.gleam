import gleeunit
import support/recording

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn owned_lifetimes_parentage_terminal_metadata_and_end_counts_test() {
  recording.check_lifecycle()
}

pub fn disabled_creates_no_recorded_spans_test() {
  recording.check_disabled()
}

pub fn unsampled_does_not_change_business_callbacks_test() {
  recording.check_unsampled()
}

pub fn absent_metadata_is_not_fabricated_test() {
  recording.check_absent_metadata()
}

pub fn http_server_logical_and_attempt_spans_have_explicit_parentage_test() {
  recording.check_http_hierarchy()
}
