//// Host entry point. scripts/validate_otel.sh bootstraps exporter dependencies
//// before the SDK instead of relying on generated application startup order.

import local_validation/business
import local_validation/host

pub fn main() -> Nil {
  host.check_recording(business.exercise)
  host.check_otlp(business.exercise)
}
