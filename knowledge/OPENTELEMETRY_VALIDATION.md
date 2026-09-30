# OpenTelemetry Validation Runbook

This runbook describes the maintained local gates for Pig tracing. Run commands
from the repository root with the source tree and dependency pins under review.
It does not record one machine's output or temporary evidence.

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

## What the integration gate proves

The local-validation host uses an official SDK simple processor/recording path
and a separate official batch processor with OTLP HTTP/protobuf. The loopback
receiver decodes official protobuf and acknowledges the complete expected span
set before SDK shutdown. `force_flush` returning is not accepted as proof of
remote delivery. Recording-only results and exporter refusal test instrumentation
and business non-interference, not delivery.

The harness runs real public Pig buffered/streamed operations and a real proxy
server/upstream/client for both `/v1/chat/completions` and `/v1/responses`, in
buffered and streaming modes. Fixtures live under
`packages/pig_otel/examples/local_validation/test_data/`; host, receiver and
verification harness live under that example's `src/` and `test/` trees. The
shared SDK recording fixture is in `packages/pig_otel/fixtures/sdk_recording/`.
The verifier checks consumer scope, span identity/parentage, terminal metadata,
usage, context in callbacks, exactly-once recording and absence of sensitive
sentinels. Streaming tests hold upstream completion until downstream handoff to
check all three lifetimes; death/handoff and runtime-stop tests exercise ownership
and cancellation boundaries. The host explicitly starts exporter and consumer
dependency applications before SDK setup and tracer acquisition.

Integration wrappers under `test/integration/` compile normally but execute only
when the host explicitly sets `PIG_RUN_OTEL_INTEGRATION=1`. Root package unit
checks do not require SDK or collector configuration. Do not mistake skipped
network wrappers for the enabled local integration run.

## Warning policy

The clean dependency graph currently emits nine known `gleam_http.Header`
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
