# pig

A library and proxy ecosystem for running agent inference against provider-agnostic language-model endpoints on the BEAM.

## Proxy language

**Proxy Request**:
A client inference request accepted by `pig_proxy` for execution against one or more upstream targets.
_Avoid_: Incoming request, job

**Upstream Target**:
A configured language-model endpoint — a base URL plus credentials, identified by its slug (e.g. "openai", "codex") — eligible to execute a proxy request. A target serves many models; the model is not part of its identity.
_Avoid_: Provider, backend, server, model

**Fallback Chain**:
The ordered upstream targets eligible to execute a proxy request when an earlier target cannot complete it.
_Avoid_: Provider list, failover list

**Per-Target Retry Budget**:
The maximum additional attempts allowed on each upstream target in a fallback chain. The budget resets when execution moves to the next upstream target.
_Avoid_: Global retries, max retries

**Commit Point**:
The moment a proxy request forwards its first successful byte to the client. Before it, a failed attempt may retry or move to the next fallback target; after it, the request is committed and can no longer retry or fall back.
_Avoid_: Point of no return, response start

**Target Authentication**:
How an upstream target proves its identity to the upstream: either a static API key (`ApiKey`) or ChatGPT/Codex OAuth (`Codex`), where the live token is resolved from the credential vault at request time. One concept per target — the two cannot be mixed or disagree.
_Avoid_: api key, codex token, credentials (when meaning the per-target auth mode)
