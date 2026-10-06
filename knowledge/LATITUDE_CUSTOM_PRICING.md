# Latitude cloud custom model pricing (source review)

**Scope:** public checkout `db60184a2fdbd27b143bd1e3b7778f48d47b13ee`. No authenticated or live cloud calls were made. This establishes what this source snapshot implements; it does **not** prove what Latitude cloud may offer privately, via an unbundled service, or in a newer release.

## Live models.dev comparison

A direct unauthenticated fetch of [the live models.dev API](https://models.dev/api.json) after reviewing the Latitude snapshot confirms all configured OpenAI IDs are present upstream. Base USD/million-token input/output/cache-read rates are:

| Model | Input | Output | Cache read |
|---|---:|---:|---:|
| `gpt-6-sol` | 2 | 10 | 0.2 |
| `gpt-6-luna` | 0.1 | 0.5 | 0.01 |
| `gpt-6.1-sol` | 2 | 10 | 0.1 |

All also list higher long-context rates. Therefore the inspected Latitude **bundled snapshot** is behind the live upstream catalog for these entries; models.dev itself is not missing them. Latitude cloud's deployed snapshot still has not been verified. Updating upstream models.dev is unnecessary for these existing entries; Latitude needs to refresh/deploy its copy if cloud uses the same stale snapshot.

## Findings

- **No per-model price setting or API is present in this checkout.** Model pricing is loaded from the bundled `models.dev.json` catalog (`packages/domain/models/src/registry.ts:4-9`) and `getCostSpec` uses that catalog to provide estimates (`registry.ts:228-252`). The public operation manifest enumerates the operations exposed by this source (`packages/operations/src/operations/index.ts:1-53`); it contains no model-pricing/settings module. Searches of operation definitions likewise found cost analytics and trace APIs, but no mutation endpoint for model rates. This supports “not implemented in the examined source/public API”, not a definitive statement about current cloud capabilities.
- **Workspace/provider settings are not custom pricing controls in the examined API.** The operation manifest includes projects, account, members, etc., but no pricing configuration surface. This is evidence bounded to the checked-out source—not a claim about private cloud controls.
- **OTLP-reported costs are the supported per-span override mechanism in this code.** The parser recognizes `gen_ai.usage.input_cost` and `.output_cost`, plus total aliases `.total_cost` and `.cost` (`packages/domain/spans/src/otlp/resolvers/usage.ts:8-20, 140-145`). Values are USD converted to microcents (`usage.ts:9-20`). The cost resolver uses reported side values where present and estimates only missing sides from the catalog; a stated total wins for total cost (`packages/domain/spans/src/helpers/estimate-span-cost.ts:111-153`). Reported side costs, including explicit zero, override their respective sides; a zero side alone does not establish provider-reported provenance. The shared helper accepts a zero total, but the OTLP total candidates discard zero through a truthiness check (`usage.ts:18-20`). Client-computed estimates sent this way are classified as provider-reported, so they must not be presented as actual subscription charges.
- **Precedence:** per-side explicit costs beat catalog estimates for that side; unreported sides can still be catalog-estimated. An explicit total controls stored total, even if the derived sides do not sum to it. With both input and output costs provided, estimation is skipped (`estimate-span-cost.ts:128-153`). The `costSource` records provider-reported vs estimated (`estimate-span-cost.ts:145-161`).
- **Existing traces are not repriced by changing a catalog entry in this snapshot.** Resolution calculates costs as part of span transformation and writes `costInputMicrocents`, `costOutputMicrocents`, and `costTotalMicrocents` onto the span (`packages/domain/spans/src/otlp/transform.ts:252-258`); the stored span schema includes numeric cost fields (`packages/domain/spans/src/entities/span.ts:194-196`). The pricing helper explicitly describes live ingestion and trace imports as the sinks that resolve cost (`estimate-span-cost.ts:46-53, 113-120`). No repricing/backfill operation is exposed in the public operation manifest. Re-import/resubmission may recalculate a newly ingested copy, but this is not an in-place repricing feature and should not be assumed to update existing records.

## Primary sources

All links are pinned to the inspected commit:

- [Pricing registry](https://github.com/latitude-dev/latitude-llm/blob/db60184a2fdbd27b143bd1e3b7778f48d47b13ee/packages/domain/models/src/registry.ts)
- [OTLP usage/cost parser](https://github.com/latitude-dev/latitude-llm/blob/db60184a2fdbd27b143bd1e3b7778f48d47b13ee/packages/domain/spans/src/otlp/resolvers/usage.ts)
- [Cost precedence](https://github.com/latitude-dev/latitude-llm/blob/db60184a2fdbd27b143bd1e3b7778f48d47b13ee/packages/domain/spans/src/helpers/estimate-span-cost.ts)
- [Span transformation](https://github.com/latitude-dev/latitude-llm/blob/db60184a2fdbd27b143bd1e3b7778f48d47b13ee/packages/domain/spans/src/otlp/transform.ts)
- [Span schema](https://github.com/latitude-dev/latitude-llm/blob/db60184a2fdbd27b143bd1e3b7778f48d47b13ee/packages/domain/spans/src/entities/span.ts)
- [Public operation manifest](https://github.com/latitude-dev/latitude-llm/blob/db60184a2fdbd27b143bd1e3b7778f48d47b13ee/packages/operations/src/operations/index.ts)
