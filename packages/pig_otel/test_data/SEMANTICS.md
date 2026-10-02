# Semantic Test Baseline

These sources define the independent expectations used by the semantic test
matrices at GenAI snapshot `8a3767d6c5d09bc0917722720973c0c44182d960`.

Primary source:
https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/docs/gen-ai/openai.md

Mapping expectations:

- Inference name is `{gen_ai.operation.name} {gen_ai.request.model}`, CLIENT.
- The snapshot declares `openai.api.type` with values `chat_completions` and
  `responses`; it does not declare an inference operation called `responses`.
  The conversational Responses mapping uses `chat`, with
  API refinement `openai.api.type=responses` and service identity only when known.
- `gen_ai.usage.cache_read.input_tokens` corresponds to
  `usage.input_tokens_details.cached_tokens` or a similar response field.
- Cache-read input is included in `gen_ai.usage.input_tokens`, not additional
  usage to add to that aggregate. Response ID/model and finish reasons are
  separate response facts, not copies of the request model/default settings.

Generic inference/tool source:
https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/docs/gen-ai/gen-ai-spans.md

Agent source:
https://github.com/open-telemetry/semantic-conventions-genai/blob/8a3767d6c5d09bc0917722720973c0c44182d960/docs/gen-ai/gen-ai-agent-spans.md

The matrices are acceptance expectations, not generated from production mapping.
Unknown provider defaults, missing totals, response content, and schema URLs are
not guessed. The protocol's normalized stop reasons lose provider-specific detail;
this package deliberately reports that normalized bounded vocabulary, with raw
Unknown values replaced by `unknown`.
