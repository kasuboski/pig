# OpenTelemetry Validation Runbook

This runbook describes the maintained local gates for Pig tracing and their
verified scope. Run commands from the repository root with the source tree and
dependency pins under review; this is a maintained validation matrix, not a
machine-specific historical report.

## Prerequisites

Install the versions selected by `mise.toml` with mise. The clean host build also
needs `cc` for SQLite's native component. If unavailable on Nix, provide a
compiler in the command environment, for example:

```sh
nix shell nixpkgs#gcc -c mise run test-integration-otel
```

No model credentials, paid service or external collector is required. The local
integration fixture uses loopback HTTP. Dependency resolution needs network
access to official Git/Hex sources. The runner clears ambient `OTEL_*` variables
to avoid host configuration changing test behavior.

## Gates

Run the three normal root gates and the clean SDK/OTLP integration gate:

```sh
mise run build
mise run check
mise run test
mise run test-integration-otel
```

The first three build examples, check compilation and run unit suites. The OTLP
gate is implemented by `scripts/validate_otel.sh`: it copies package/script
inputs into an isolated temporary worktree, fingerprints the source copy, and
builds/tests there without changing production manifests or build outputs. It
runs `scripts/test_otel_warning_gate.sh`, performs clean dependency builds,
strict native compilation, runs the local host unit verifier and explicitly
enables its network integration tests, then runs the shared official SDK fixture.
The isolated worktree is removed on exit by default.

The script supports two optional diagnostics controls:

- `PIG_OTEL_EVIDENCE_DIR`: choose a directory for logs, source fingerprint and
  fixture evidence; defaults to `/tmp/pig-otel-evidence/local-validation`.
- `PIG_OTEL_KEEP_WORKDIR=1`: retain the temporary worktree for investigation.

These are general runner interfaces; callers should choose any suitable local
path. Retained evidence is diagnostic output, not a repository input or substitute
for rerunning the gates.

## What the integration gate exercises

The local-validation host uses official SDK recording and a separate official
batch processor with OTLP HTTP/protobuf. Its loopback receiver decodes protobuf
and acknowledges the expected span set before SDK shutdown; `force_flush` alone
is not proof of delivery. Recording-only and exporter-refusal cases establish
instrumentation/business non-interference, not delivery.

The maintained gates pass:

- `mise run build`, `mise run check`, and `mise run test` pass. The root test
  total is 1,001: 505 `pig`, 102 `pig_otel`, 144 `pig_protocol`, 235
  `pig_proxy`, and 15 `pig_transport`.
- A clean `mise run test-integration-otel` passes 28 entries: 24 enabled
  integration wrappers plus four ungated verifier checks. The unchanged shared
  official SDK suite passes five tests. The warning gate passes 12 checks.
- The clean dependency compiler output retains exactly nine visible
  `gleam_http.Header` deprecations from Mist/Gramps, as allowed by the narrow
  warning policy; project warnings remain errors.

Direct SDK/OTLP acceptance covers built-in OpenAI Chat Completions and Responses
using deterministic streaming transport adapters through public buffered and
stream-first operations. Four runs each produce two
inferences and a tool span: 16 spans, all received and acknowledged as real OTLP
HTTP/protobuf. Exact GenAI content JSON goldens for both rounds verify authored
system instructions, absence of the original private post-hook input,
default nested tool-argument/result redaction, and omission of generated tool
descriptions, schemas and thinking. The whole exported span set is privacy
checked. Authored `system_instructions` capture excludes the generated tool
description block; it is not an assertion that the entire provider
`InferenceRequest.system_prompt`, raw wire payload, or custom-provider transforms
are captured. Provider prompt bytes/order are unchanged.

The proxy shared-SDK gate also passes for both Chat Completions and Responses,
buffered and streaming. It observes 12 content-positive spans, 16 retry spans,
six interrupted spans, plus malformed/overflow, metadata-only, disabled/no-SDK,
always-off sampling, shared-policy configuration, and the original full proxy
race matrix.

For direct Pig, eight outgoing `traceparent` observations correlate with actual
inference spans; transport children intentionally receive no implicit context.
Four scoped tool callbacks correlate with tool spans. Two caller trace contexts
are reused across the four API/mode combinations; identical caller facts are
deduplicated by the fixture's ETS bag. Metadata-only preserves all 16 spans
without conversation attributes. Disabled, no-SDK and always-off leave business
results unchanged and export zero spans. These counts distinguish wrapper
entries from content-positive and receiver-acknowledged span sets; they are not
broader delivery guarantees.

Separate pinned-schema validation passes for 92 actual exported content
attributes: 32 each from direct SDK recording and OTLP receipt, and 14 each from
proxy SDK recording and OTLP receipt. This schema-validation invocation is
separate from the ordinary checked-in test gate.

Production proxy forwarding remains unchanged; projection does not mutate
upstream/downstream payloads. These checks validate only exercised projections,
SDK recording and receiver-acknowledged OTLP spans. They do not establish every
backend's rendering, retention, or truncation behavior, or physical downstream
wire delivery. Direct projection is bounded at inference boundaries; proxy input
and buffered output projection are synchronous, while SSE projection runs
incrementally on the observation path. None is a zero-latency guarantee, and
proxy SSE capture does not wait for the complete stream before forwarding it.

Integration wrappers under `test/integration/` compile normally but execute only
when the host explicitly sets `PIG_RUN_OTEL_INTEGRATION=1`. Root package unit
checks do not require SDK or collector configuration. The maintained content
contract and out-of-scope guarantees are in
[OPENTELEMETRY_CONTENT_CAPTURE.md](OPENTELEMETRY_CONTENT_CAPTURE.md). Do not
mistake skipped network wrappers for the enabled local integration run.

## Warning policy

The clean dependency graph emits exactly nine known `gleam_http.Header`
deprecations from Mist 6.0.3 and Gramps 6.0.1. They remain visible in compiler
logs and are accepted as a documented upstream limitation; do not patch, fork,
or vendor dependencies to remove them. `scripts/check_otel_warnings.awk` accepts
only the matching dependency source locations, type and replacement diagnostic.
All project-source warnings, unrelated dependency warnings, native compiler
warnings and malformed/unrecognized diagnostics remain failures. The root build
and check retain their warnings-as-errors behavior.

`scripts/test_otel_warning_gate.sh` runs 12 regression checks covering the exact
known warning forms and rejection of project, unrelated, altered, mixed and
incomplete diagnostics. Keep this test in the clean integration gate if the
warning policy changes; do not suppress or discard raw compiler logs.

## Limits and maintenance

A passing gate proves only the exercised supported configuration. No-SDK,
Disabled, always-off sampling and refused-exporter cases establish business
non-interference, not successful export. Custom throwing processors/loaders,
directly configured baggage propagators, in-flight SDK restart, hard owner kill,
VM death, physical socket drain and final wire delivery are not guarantees.
Host-specific resources, credentials, TLS, sampling, endpoint configuration and
collector routing require deployment-level verification. Update this runbook
when maintained scripts, fixtures, dependency pins or supported behavior change;
keep ephemeral evidence and historical review narratives out of this document.
