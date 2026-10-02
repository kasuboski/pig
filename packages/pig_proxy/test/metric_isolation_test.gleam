import gleam/dict
import gleam/erlang/process
import gleam/option.{Some}
import gleeunit
import pig_proxy/metrics
import pig_proxy/model_catalog
import pig_proxy/telemetry
import support/metric_isolation_harness as harness

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn emit_scoped_routes_only_normalized_events_to_own_runtime_test() {
  telemetry.ensure_started()
  let audit = process.new_subject()
  let handler = telemetry.attach_typed(fn(event) { process.send(audit, event) })
  let a = harness.start("metric_isolation_a")
  let b = harness.start("metric_isolation_b")
  let ids_a = harness.identities(harness.catalog_a, "provider-a", "target-a")
  let ids_b = harness.identities(harness.catalog_b, "provider-b", "target-b")
  let emitter_a = metrics.emitter(a.name, ids_a)
  let emitter_b = metrics.emitter(b.name, ids_b)
  let event_a = harness.event("shared-model", "provider-a", "target-a")
  let event_b = harness.event("other-model", "provider-b", "target-b")

  let assert telemetry.RequestStop(
    target_id: own_target,
    provider: own_provider,
    ..,
  ) = telemetry.normalize_with(event_a, ids_a)
  let assert telemetry.RequestStop(
    target_id: other_target,
    provider: other_provider,
    ..,
  ) = telemetry.normalize_with(event_a, ids_b)
  assert #(own_target, own_provider) == #("target-a", "provider-a")
  assert #(other_target, other_provider) == #("unknown", "unknown")

  telemetry.emit_scoped(emitter_a, event_a)
  telemetry.emit_scoped(emitter_b, event_a)
  telemetry.emit_scoped(emitter_a, event_b)
  telemetry.emit_scoped(emitter_b, event_b)

  let snapshot_a = metrics.get_snapshot(a.subject)
  let snapshot_b = metrics.get_snapshot(b.subject)
  assert harness.model_count(snapshot_a) == 2
  assert harness.model_count(snapshot_b) == 2
  let assert Ok(known_a) =
    dict.get(snapshot_a.models, "provider-a/shared-model")
  let assert Ok(unknown_a) = dict.get(snapshot_a.models, "unknown/unknown")
  let assert Ok(unknown_b) = dict.get(snapshot_b.models, "unknown/shared-model")
  let assert Ok(known_b) = dict.get(snapshot_b.models, "provider-b/other-model")
  assert known_a.request_count == 1
  assert unknown_a.request_count == 1
  assert known_b.request_count == 1
  assert unknown_b.request_count == 1

  let assert Ok(original_a) = process.receive(audit, 1000)
  let assert Ok(original_b) = process.receive(audit, 1000)
  let assert Ok(original_c) = process.receive(audit, 1000)
  let assert Ok(original_d) = process.receive(audit, 1000)
  assert original_a == event_a
  assert original_b == event_a
  assert original_c == event_b
  assert original_d == event_b

  telemetry.detach_typed(handler)
  harness.stop(a)
  harness.stop(b)
}

pub fn parsed_catalogs_keep_runtime_model_pricing_separate_test() {
  let catalog_a = harness.catalog_a()
  let catalog_b = harness.catalog_b()
  let assert Some(info_a) =
    model_catalog.find(catalog_a, "provider-a/shared-model")
  let assert Some(info_b) =
    model_catalog.find(catalog_b, "provider-b/shared-model")
  assert model_catalog.cost_usd(info_a, 1_000_000, 1_000_000, 0) == 3.0
  assert model_catalog.cost_usd(info_b, 1_000_000, 1_000_000, 0) == 16.0
}
