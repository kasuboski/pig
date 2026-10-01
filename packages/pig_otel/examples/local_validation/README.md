# Local OpenTelemetry Validation Host

This example is a host, not a production Pig dependency. The root build discovers
its `gleam.toml` normally. Network integration modules live in `test/integration/`
and compile with ordinary tests; only their execution requires
`PIG_RUN_OTEL_INTEGRATION=1`. Pure verifier unit tests are never gated. This is
intended as a release gate for tracing and opt-in proxy content contracts;
unsupported cases remain documented separately. The clean SDK/OTLP content gate
has passed; the runbook records its scope and the distinction between receiver
acknowledgement and broader delivery guarantees.

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

The script copies all package and script inputs into an isolated temporary
worktree (no built artifacts), fingerprints that complete copy before building,
resolves the real HTTPS binding revision through Pig dependencies,
builds the host exporter, builds/checks the normal example/test target, runs
ungated unit tests, then explicitly enables integration tests. It removes the worktree on success or failure by default;
`PIG_OTEL_KEEP_WORKDIR=1` retains it for diagnosis. `PIG_OTEL_EVIDENCE_DIR` can
select an evidence directory when diagnostic artifacts are needed.

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

The host runs public Pig operations and real proxy requests against a loopback
upstream for both `/v1/chat/completions` and `/v1/responses`, buffered and
streaming. It requires no paid API, credentials, external provider or external
collector.

Official SDK recording cases separate metadata-only privacy and explicit
conversation capture. The final clean gate passed with 19 enabled integration
checks and 4 ungated verifier checks (23 passed with integration enabled); a
separate invocation verifies the ungated suite. With the integration flag off,
the unit invocation reports 23 passed, including 19 integration no-ops, not 23
true unit tests. The shared-SDK runtime suite passed 5 tests. Positive buffered and streaming capture produced 12
actual consumer spans across both routes, verified through SDK recording and
OTLP receiver acknowledgement. Other cases cover tool linkage, bounded/redacted
values, malformed streamed JSON, source overflow, retry after a failed 503
attempt, capture configured without an SDK or with sampling off, `Disabled`
precedence, and interruption with truthful omitted/incomplete content and
failed/cancelled outcomes. A deliberately small SDK value limit demonstrates
that host truncation can invalidate otherwise valid JSON. Three fresh-VM
interrupted-run repeats each recorded six spans across both routes; a full-span
privacy sentinel scan and pure regression checks passed. A deterministic graceful
owners-supervisor teardown barrier prevents the interrupted-fixture snapshot
race. See the [validation runbook](../../../../knowledge/OPENTELEMETRY_VALIDATION.md) for the
scope and caveats.

Production forwards the effective API request payload unchanged; verified
forwarding does not apply production normalization. Input projection is bounded synchronous work before
send, buffered output projection is bounded synchronous work before return, and
SSE projection occurs incrementally on the stream observation path. This adds
bounded overhead, not zero latency; SSE capture does not wait for the entire
stream before forwarding it.

The delivery path uses the official batch processor and OTLP HTTP/protobuf
exporter. The loopback receiver decodes official protobuf and acknowledges the
expected span set before SDK shutdown. The integration matrix includes positive
opt-in content and separate metadata-only privacy cases. These checks do not
promise delivery for arbitrary exporters, sampling configurations, or backends.

Startup explicitly starts exporter dependencies (including inets) and consumer
dependency applications (including Mist's clock) **before** SDK setup and
consumer tracer acquisition. Never launch the generated Gleam entrypoint
as proof of correct startup ordering; it can start SDK too early. The script uses
bare Erlang and the public test entrypoint after explicit bootstrap.

## Honest Limits

Disabled policy, no-SDK, always-off sampling and a refused loopback exporter endpoint verify unchanged business results, **not successful export**. Ordinary exporter
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
instrumentation. Rich audit data and VM crash reports are outside the OTel
conversation-capture privacy contract.
