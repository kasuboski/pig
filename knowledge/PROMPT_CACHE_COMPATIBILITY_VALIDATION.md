# Responses prompt-cache compatibility verification

Implements [issue #38's compatibility proposal](https://github.com/kasuboski/pig/issues/38#issuecomment-6142072623).

## Contract

Every physical buffered or streaming Responses attempt derives its effective
body from the original logical request and the selected target:

```text
exact-model override > explicit target default > authentication default
API key: preserve                  Codex OAuth: omit
```

Only top-level `prompt_cache_options` is removed. Other JSON values are
preserved, including nested fields, cache keys and retention. Formatting/key
order may change when removal is required. Unaffected, malformed and non-object
bodies retain their exact bytes. HTTP 400 remains a committed upstream response,
not an instruction to retry without the field. The HTTP server's routing policy
is unchanged; fallback restoration tests exercise the existing execution seam.

The builders configure targets programmatically; no model-name heuristic or
new environment-variable contract is introduced. Codex defaults also apply to
the existing subscription host without changing that host's configuration.

## Local verification

All commands below completed successfully on the implementation branch:

| Command | Result |
| --- | --- |
| `mise run build` | All library packages and self-contained examples compile; warnings treated as errors |
| `mise run test` | 1,047 tests: pig 505, pig_otel 118, pig_protocol 144, pig_proxy 265, pig_transport 15; zero failures |
| `mise exec -- bash -c 'cd packages/pig_proxy && gleam format --check && gleam check'` | Formatted, no diagnostics |
| `mise run test-integration-prompt-cache` | Six real loopback HTTP cases pass |
| `mise run test-subscriptions` | 31 subscription-host tests pass |
| `mise run test-integration-subscriptions` | Subscription HTTP, OTLP wire, shutdown/failure acceptance passes |
| `git diff --check` | Clean |

The loopback test asserts both buffered and streaming outcomes:

| Selected model policy | Synthetic upstream result | Wire assertion |
| --- | --- | --- |
| API-key default preserve, unsupported model | 400 invalid_parameter | Original body byte-for-byte; no retry despite available retry budget |
| Exact-model omit | 200 completed | Only top-level parameter removed; nested parameter/cache key/retention unchanged |
| Exact-model preserve, supported model | 200 completed | Original body byte-for-byte |

Pure tests cover malformed/non-object bodies, arbitrary option value shapes,
Unicode/escaped strings, JSON null/bools/floats/large integers, nested options,
Chat Completions isolation and exact/case-sensitive override precedence.
Execution tests cover authentication defaults, `with_codex`, explicit target
and model overrides, replacement of an override, and restoration of the original
body on both buffered and streaming fallback.

Focused loopback output:

```text
PASS: 6 loopback Responses cases (buffered + streaming; 400 forwarding, omission, preservation; exact upstream bodies)
```

## Live provider proof

Run the opt-in probe (requires `uv`; Python standard library only):

```sh
mise run test-live-prompt-cache
# Optional: UPSTREAM_BASE_URL / UPSTREAM_API_KEY
```

The observed tailnet upstream was `http://llms/v1`, model **gpt-6-luna**, reasoning
**low**. The request uses list-shaped Responses input, `store:false`,
`stream:true`, and `prompt_cache_options:{"mode":"explicit"}`. The probe launches
real Pig HTTP listeners behind a recording loopback forwarder. It compares
upstream wire bodies, verifies exactly one physical send, and checks the
`response.completed` event's status and actual `CACHE_OK` output. Credentials and
response contents are not persisted.

Observed output:

```text
Model: gpt-6-luna; reasoning: low
direct explicit-cache: HTTP 400, prompt_cache_options is not supported on this model
direct omitted: HTTP 200, completed CACHE_OK
Pig preserve: HTTP 400; option preserved byte-for-byte; one physical attempt
Pig exact-model omit: HTTP 200; completed CACHE_OK; only top-level option removed
PASS: live streaming Responses through real Pig listeners and recorded upstream wire bodies
Buffered path is covered by synthetic HTTP tests: this upstream requires stream=true.
```

This is a live reproduction of the reported error and a successful targeted fix,
not merely a synthetic provider claim. The probe also allows a supporting upstream
to return 200 for the original request rather than incorrectly demanding failure.

## Limits and unsuccessful exploratory runs

- The original production route/model/auth mode and installed Pi revision remain
  unconfirmed. This does not assert they matched the live route tested here.
- Pi's actual `completeSummarization` function and automatic token-threshold
  compaction trigger were not exercised; requests reproduce its explicit-cache
  parameter shape at the Responses boundary.
- No live direct ChatGPT/Codex OAuth probe was run. The Codex default is based on
  source behavior and verified by the execution policy matrix, not a universal
  claim about Codex-compatible backends.
- This tailnet backend rejects buffered requests with `Stream must be set to
  true`. Buffered Pig behavior is therefore verified by real synthetic HTTP, not
  by this provider. Initial string-shaped input probes were also rejected before
  testing cache compatibility; the final harness uses accepted list input.
- An exploratory full `PIG_RUN_INTEGRATION=1 gleam test` run passed the new loopback
  test but failed the unrelated existing live Chat Completions test with 502:
  its default localhost provider was unavailable. The focused loopback task,
  full default package suite, and separate live Responses probe all pass.
- Omission restores upstream default caching. It cannot enforce suppression of
  cache writes on an endpoint that lacks explicit prompt-cache mode.
