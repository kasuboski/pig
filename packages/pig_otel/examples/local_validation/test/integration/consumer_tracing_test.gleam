//// Normally compiled. No model credentials, collector or paid API required.

import local_validation/business
import local_validation/host

pub fn managed_proxy_shutdown_flush_delivery_test() -> Nil {
  case host.integration_enabled() {
    True -> host.check_runtime_shutdown()
    False -> Nil
  }
}

pub fn official_sdk_recording_test() -> Nil {
  case host.integration_enabled() {
    True -> host.check_recording(business.exercise)
    False -> Nil
  }
}

pub fn official_otlp_delivery_test() -> Nil {
  case host.integration_enabled() {
    True -> host.check_otlp(business.exercise)
    False -> Nil
  }
}

pub fn no_sdk_sampling_exporter_outage_test() -> Nil {
  case host.integration_enabled() {
    True -> host.check_limitations(business.exercise)
    False -> Nil
  }
}

pub fn disabled_policy_preserves_business_and_propagation_test() -> Nil {
  case host.integration_enabled() {
    True -> host.check_disabled(business.exercise_disabled)
    False -> Nil
  }
}

pub fn official_pig_callbacks_recording_test() -> Nil {
  case host.integration_enabled() {
    True -> host.check_agent_recording(business.exercise_agents)
    False -> Nil
  }
}

pub fn official_proxy_sync_scopes_recording_test() -> Nil {
  case host.integration_enabled() {
    True -> host.check_proxy_recording(business.exercise_proxy_sync)
    False -> Nil
  }
}

pub fn official_sdk_streaming_race_matrix_test() -> Nil {
  case host.integration_enabled() {
    True -> host.check_stream_races()
    False -> Nil
  }
}

pub fn official_proxy_sync_otlp_test() -> Nil {
  case host.integration_enabled() {
    True -> host.check_proxy_otlp(business.exercise_proxy_sync)
    False -> Nil
  }
}

pub fn actual_provider_failure_status_privacy_delivery_test() -> Nil {
  case host.integration_enabled() {
    True -> host.check_failure(business.exercise_failure)
    False -> Nil
  }
}
