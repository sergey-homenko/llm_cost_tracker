# Grok 4.20 Multi-Agent Beta

Multiple agents collaborate in parallel to perform deep research tasks.

## At a glance

- **Modalities:** text, image → text
- **Context window:** 1,000,000 tokens
- **Model name:** `grok-4.20-multi-agent-0309`
- **Aliases:** `grok-4.20-multi-agent`, `grok-4.20-multi-agent-latest`, `grok-4.20-multi-agent-beta-latest`, `grok-4.20-multi-agent-experimental-beta-0304`, `grok-4.20-multi-agent-experimental-beta-latest`, `grok-4.20-multi-agent-beta-0309`
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
| Requests per second | 9 |
| Tokens per minute | 2,500,000 |

## Regions

Available in: us-east-1, us-west-2
