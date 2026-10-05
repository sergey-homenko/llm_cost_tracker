# Grok 4.6

SpaceXAI's frontier model for coding, agentic tasks, and knowledge work.

## At a glance

- **Modalities:** text, image → text
- **Context window:** 500,000 tokens
- **Model name:** `grok-4.6`
- **Batch API:** Not supported

## Capabilities

- **Function calling:** Yes
- **Structured outputs:** Yes
- **Reasoning:** Yes
- **Reasoning efforts (supported):** `low`, `medium`, `high`, `xhigh`
- **Reasoning efforts (default):** `high`

## Pricing

| Type | < 200k prompt tokens (per 1M tokens) | ≥ 200k prompt tokens (per 1M tokens) |
| --- | --- | --- |
| Input | $2.00 | $4.00 |
| Cached input | $0.50 | $1.00 |
| Output | $6.00 | $12.00 |

Requests whose prompt reaches 200k tokens are billed at the higher rate for all tokens in the request.

## Rate limits

| Limit | Value |
| --- | --- |
| Requests per second | 150 |
| Tokens per minute | 50,000,000 |

## Regions

Available in: us-east-1, us-west-2, us-central-1
