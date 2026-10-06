import gleeunit/should

@external(erlang, "pig_subscriptions_exporter_config_ffi", "check")
fn check_exporter_config() -> Bool

pub fn configured_exporter_pipeline_is_preserved_test() {
  should.equal(check_exporter_config(), True)
}
