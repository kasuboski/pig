import support/check

pub fn duplicate_end_is_rejected_test() -> Nil {
  check.check_verifier("duplicate_end")
}

pub fn wrong_trace_parent_is_rejected_test() -> Nil {
  check.check_verifier("wrong_parent")
}

pub fn metadata_privacy_checks_nested_content_test() -> Nil {
  check.check_verifier("privacy")
}
