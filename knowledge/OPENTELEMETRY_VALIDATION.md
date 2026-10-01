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

## What the integration gate exercises

The local-validation host uses official SDK recording and a separate official
batch processor with OTLP HTTP/protobuf. Its loopback receiver decodes protobuf
and acknowledges the expected span set before SDK shutdown; `force_flush` alone
is not proof of delivery. Recording-only and exporter-refusal cases establish
instrumentation/business non-interference, not delivery.

The gate covers public buffered and streamed Pig runs and real proxy requests
for both `/v1/chat/completions` and `/v1/responses`. The final clean SDK/OTLP gate
passed with 19 enabled integration checks and 4 ungated verifier checks
(23 passed with integration enabled); a separate
invocation verifies the ungated suite. With the integration flag off, the unit
invocation reports 23 passed, including 19 integration no-ops; those are not 23
true unit tests. The shared SDK suite passed 5 tests. The final root build/check/test
gates also passed; the package test runner reported 992 passed.
Evidence for the final SDK/OTLP gate is under
`/tmp/pig-otel-evidence/content-capture/final-integration-stable`. This evidence
is a test run record, not a repository input.

The content checks observed 12 actual consumer spans for the positive buffered
and streaming cases across both API routes through official SDK recording and
OTLP receiver acknowledgement. They also covered metadata-only privacy, a
retry with a failed 503 first attempt (16 actual consumer spans), malformed
streamed JSON, source overflow, configured capture with no SDK and with sampling
off, `Disabled` precedence, and a deliberately small SDK string limit that
truncated otherwise valid content JSON. The latter was treated as invalid JSON,
not successful capture. Three fresh-VM interrupted-run repeats each recorded six
actual spans across the two routes, with interrupted output omitted/incomplete
alongside failed or
cancelled outcomes. A full-span privacy sentinel scan and pure regression checks
passed. A deterministic graceful owners-supervisor teardown barrier prevents
the interrupted-fixture snapshot race. Pure projection/redaction/bounds fixtures
and lifecycle/builder tests are also included.

Production forwards the effective API request payload unchanged; verified
forwarding does not apply production normalization.

These counts prove only the exercised fixtures and SDK/OTLP receiver-acknowledged
span sets. The 19 enabled integration checks do not validate every backend's
rendering, retention, truncation policy, or physical downstream wire delivery. Streaming
cases retain the downstream first-body acknowledgement boundary and check body
preservation. Input projection is bounded but synchronous before send, buffered
output projection is synchronous before return, and SSE projection runs
incrementally on the stream observation path. None is a zero-latency guarantee,
and SSE capture does not wait for the complete stream before forwarding it.

Integration wrappers under `test/integration/` compile normally but execute only
when the host explicitly sets `PIG_RUN_OTEL_INTEGRATION=1`. Root package unit
checks do not require SDK or collector configuration. The maintained content
contract and out-of-scope guarantees are in
[OPENTELEMETRY_CONTENT_CAPTURE.md](OPENTELEMETRY_CONTENT_CAPTURE.md). Do not
mistake skipped network wrappers for the enabled local integration run.

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
