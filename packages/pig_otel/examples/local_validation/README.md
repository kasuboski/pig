# Local OpenTelemetry Validation Host

This example is a host, not a production Pig dependency. The root build discovers
its `gleam.toml` normally. Network integration modules live in `test/integration/`
and compile with ordinary tests; only their execution requires
`PIG_RUN_OTEL_INTEGRATION=1`. Pure verifier unit tests are never gated. This is a
release gate, not a declaration that all tracing lifecycles are accepted: subset
checks do not replace the full buffered/streaming matrix.

The test gate accepts the nine known Mist/Gramps Header deprecations, which remain
visible in compiler logs. It rejects project-source and unexpected warnings,
with 12 policy regression checks and no dependency patch/fork. See the
[validation runbook](../../../../knowledge/OPENTELEMETRY_VALIDATION.md).

From the repository root:

```sh
mise run test-integration-otel
```

The clean build needs a C compiler for Pig's SQLite NIF. On Nix systems without
`cc` on PATH:

```sh
nix shell nixpkgs#gcc -c mise exec -- scripts/validate_otel.sh
```

The script copies package sources into an isolated temporary worktree (no built
artifacts), fingerprints inputs before building, resolves the real HTTPS binding
revision through Pig dependencies,
builds the host exporter, builds/checks the normal example/test target, runs
ungated unit tests, then explicitly enables integration tests. It removes the
worktree on success or failure; `PIG_OTEL_KEEP_WORKDIR=1` retains it for diagnosis.
Evidence defaults to `/tmp/pig-otel-evidence/local-validation`; change it with
`PIG_OTEL_EVIDENCE_DIR`.

## Host Compatibility

- Official API 1.5.0, SDK 1.7.0, exporter 1.10.0.
- Official Hex gproc 1.3.0 replaces 1.2.0 via a declarative **host-only** Rebar
  override. grpcbox stays 0.18.0; other grpcbox dependencies stay at their reviewed
  versions. No vendoring, upstream edits, cache patches or warning suppression.
- gproc 1.3.0 hoists exported subexpression bindings and replaces deprecated
  `lists:zf/2` with equivalent `lists:filtermap/2`. The script strictly compiles
  every gproc module with `erlc -Wall -Werror`.
- Gleam cannot override the `~>1.2.0` Hex requirement declared by grpcbox, and the
  unmodified Erlang gproc repository has no Gleam manifest for Git consumption.
  Therefore the separate `host/rebar.config` owns the exporter graph. The example
  Gleam manifest owns the SDK recording compile graph. Both use identical official
  SDK/API versions. Production libraries remain API-only.

## What Is Checked

A single business harness runs real public Pig buffered and streamed agent runs
with a scripted local provider and tool. It also starts the actual proxy server,
a loopback upstream and an HTTP client, exercising both `/v1/chat/completions` and
`/v1/responses` in buffered and streaming mode. No paid API, key, collector or
external provider is used.

The recording host uses the **official simple processor and official ETS
exporter**. The delivery host uses the **official batch processor and OTLP
HTTP/protobuf exporter**. The loopback receiver uses the official protobuf
module, returns a valid HTTP acknowledgement, and provides a decoded complete-set
snapshot. A batch `force_flush` return is never treated as delivery: receiver ACK
must occur before SDK shutdown.

Both paths use the same machine-checkable normalized-span verifier: exactly 20
unique consumer spans, `pig/0.6.0` vs `pig_proxy/0.2.0` scopes with actual consumer
markers, no invented schema, parent/trace IDs, kinds, ordered end timestamps,
terminal metadata/status, usage including cached subsets, real callback current
context, tool sibling hierarchy, fresh run IDs and outbound attempt traceparent.
Each operation exports exactly once. Fixture content/credentials/baggage sentinels
must be absent from spans/events/links. The upstream asserts one fresh traceparent,
no baggage (including mixed-case duplicate ingress baggage), and correct configured
auth (without printing credentials). Streaming fixtures hold final usage/EOF until
an actual downstream first-chunk ACK; recording snapshots must show zero ended
spans for that request at the ACK, and all three exported lifetimes must contain
that timestamp. Responses and Chat fixtures use their actual distinct JSON/SSE
shapes in `test_data/`. A separate real provider-failure case checks Error status,
bounded categories, missing usage and privacy through recording and actual OTLP.

The official SDK additionally checks 18 streaming route/death-boundary cases
(54 spans), two EOF-before-handoff usage cases (6 spans), and four managed/external
runtime-stop cases (12 spans). Dormant registered owners create zero spans.
Managed active-stream shutdown also exports six Cancelled spans through actual
OTLP, after runtime.stop acknowledgement and before SDK shutdown.

Startup explicitly starts exporter dependencies (including inets) and consumer
dependency applications (including Mist's clock) **before** SDK setup and
consumer tracer acquisition. Never launch the generated Gleam entrypoint
as proof of correct startup ordering; it can start SDK too early. The script uses
bare Erlang and the public test entrypoint after explicit bootstrap.

## Honest Limits

Disabled policy, no-SDK, always-off sampling and a refused loopback exporter endpoint verify
unchanged successful business results, **not successful export**. Ordinary exporter
failure is not arbitrary VM/resource/custom-processor failure isolation. Consumer
terminal acknowledgements and HTTP application completion are not proof that
physical connections drained or every byte reached the remote client. SDK restarts
are between completed operations only; owner hard kill and VM death cannot guarantee
closure/delivery.

Happy-path end counts alone do not cover cancellation/death/handoff/retry races.
The dedicated SDK race entry runs the genuine OTP consumer harness with official
recording, without replacing the SDK with the harness's call spy. Additional
consumer unit/OTP gates remain separate and are not inferred from HTTP success.
Synthetic normalized values in unit tests validate the verifier, never Pig
instrumentation. Rich audit data and VM crash reports are outside the
metadata-only OTel privacy claim.
