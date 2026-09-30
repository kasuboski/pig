import gleam/dict
import gleam/erlang/process
import gleam/option.{None, Some}
import pig_proxy/metric_labels
import pig_proxy/metrics
import pig_proxy/model_catalog
import pig_proxy/telemetry

pub type RunningMetrics {
  RunningMetrics(
    name: process.Name(metrics.MetricsMsg),
    subject: process.Subject(metrics.MetricsMsg),
    pid: process.Pid,
  )
}

pub fn start(label: String) -> RunningMetrics {
  let name = process.new_name(label)
  let assert Ok(started) = metrics.start_named(name)
  RunningMetrics(name:, subject: started.data, pid: started.pid)
}

pub fn stop(running: RunningMetrics) -> Nil {
  process.unlink(running.pid)
  process.kill(running.pid)
}

pub fn identities(
  catalog: fn() -> model_catalog.Catalog,
  provider: String,
  target: String,
) -> metric_labels.Identities {
  metric_labels.Identities(
    catalog:,
    models: [],
    providers: [provider],
    targets: [target],
  )
}

pub fn event(
  model: String,
  provider: String,
  target_id: String,
) -> telemetry.ProxyEvent {
  telemetry.RequestStop(
    target_id:,
    provider:,
    model:,
    status: 200,
    duration_ms: 12,
    input_tokens: Some(3),
    output_tokens: Some(2),
    cached_input_tokens: None,
  )
}

pub fn model_count(snapshot: metrics.MetricsSnapshot) -> Int {
  dict.size(snapshot.models)
}

pub fn catalog_a() -> model_catalog.Catalog {
  let assert Ok(catalog) =
    model_catalog.parse(
      "{\"provider-a\":{\"models\":{\"provider-a/shared-model\":{\"cost\":{\"input\":1,\"output\":2}}}}}",
    )
  catalog
}

pub fn catalog_b() -> model_catalog.Catalog {
  let assert Ok(catalog) =
    model_catalog.parse(
      "{\"provider-b\":{\"models\":{\"provider-b/shared-model\":{\"cost\":{\"input\":7,\"output\":9}},\"provider-b/other-model\":{\"cost\":{\"input\":7,\"output\":9}}}}}",
    )
  catalog
}

pub fn empty_catalog() -> model_catalog.Catalog {
  model_catalog.empty()
}
