import support/identity_owner_harness as identity_owner

pub fn interleaved_baggage_owners_isolate_spans_retries_and_usage_test() {
  identity_owner.check_interleaved_owners()
}

pub fn shutdown_retires_owner_without_identity_bleed_test() {
  identity_owner.check_shutdown_owner()
}
