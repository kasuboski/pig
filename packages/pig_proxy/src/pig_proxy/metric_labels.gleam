//// Metric-only normalization, independent of tracing/capture/sampling.
//// Typed audit consumers retain original facts; metric/export projections use
//// only a trusted catalog/config identity or the finite unknown sentinel.

import gleam/list
import gleam/option
import pig_proxy/model_catalog

/// Trusted deployment identities, never learned from request traffic.
pub type Identities {
  Identities(
    catalog: fn() -> model_catalog.Catalog,
    models: List(String),
    targets: List(String),
    providers: List(String),
  )
}

/// Configure the legacy unscoped telemetry API. Production runtimes carry
/// immutable identities in their own emitter instead of using this default.
@external(erlang, "pig_proxy_metric_labels_ffi", "configure")
pub fn configure(identities: Identities) -> Nil

@external(erlang, "pig_proxy_metric_labels_ffi", "identities")
pub fn identities() -> Identities

/// Bounded pure label mapping for fixture matrices.
pub fn label(value: String, allowed: List(String)) -> String {
  case list.contains(allowed, value) {
    True -> value
    False -> "unknown"
  }
}

pub fn model(
  value: String,
  provider: String,
  ids: Identities,
  catalog: model_catalog.Catalog,
) -> String {
  let known =
    list.contains(ids.models, value)
    || model_catalog.find(catalog, value) != option.None
    || model_catalog.find(catalog, provider <> "/" <> value) != option.None
  case known {
    True -> value
    False -> "unknown"
  }
}
