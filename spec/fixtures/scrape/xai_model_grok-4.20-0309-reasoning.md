# Grok 4.20

Grok 4.20 is a high-performance model with industry-leading speed and agentic tool calling capabilities. It combines the lowest hallucination rate on the market with strict prompt adherence, delivering consistently precise and truthful responses.

## At a glance

- **Modalities:** text, image → text
- **Context window:** 1,000,000 tokens
- **Model name:** `grok-4.20-0309-reasoning`
- **Aliases:** `grok-4.20-reasoning-latest`, `grok-4.20`, `grok-4.20-reasoning`, `grok-4.20-0309`, `grok-4.20-beta-0309-reasoning`, `grok-4.20-beta`, `grok-4.20-beta-0309`, `grok-4.20-beta-latest`, `grok-4.20-beta-latest-reasoning`, `grok-4.20-beta-reasoning`, `grok-4.20-experimental-beta-0304-reasoning`, `grok-4.20-experimental-beta-0304`, `grok-4.20-experimental-beta-reasoning-latest`, `grok-4.20-experimental-beta-latest`, `grok-4.20-reasoning-gv2`
- **Batch API:** Supported

## Capabilities

- **Function calling:** Yes
- **Structured outputs:** Yes
- **Reasoning:** Yes

## Pricing

| Type | < 200k prompt tokens (per 1M tokens) | ≥ 200k prompt tokens (per 1M tokens) |
| --- | --- | --- |
| Input | $1.25 | $2.50 |
| Cached input | $0.20 | $0.40 |
| Output | $2.50 | $5.00 |

Requests whose prompt reaches 200k tokens are billed at the higher rate for all tokens in the request.

[Batch API](/developers/advanced-api-usage/batch-api) requests are billed at a 20% discount to standard rates.

## Rate limits

| Limit | Value |
| --- | --- |
| Requests per second | 37 |
| Tokens per minute | 10,000,000 |

## Regions

Available in: us-east-1, us-west-2
