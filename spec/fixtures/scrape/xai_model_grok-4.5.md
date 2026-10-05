# Grok 4.5

SpaceXAI's intelligent coding model for agentic software, engineering, and workflow tasks. Trained in SpaceXAI's data centers in Memphis with new datasets spanning science, engineering, and math.

## At a glance

- **Modalities:** text, image → text
- **Context window:** 500,000 tokens
- **Model name:** `grok-4.5`
- **Aliases:** `grok-4.5-latest`, `grok-build-latest`
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
| Cached input | $0.30 | $0.60 |
| Output | $6.00 | $12.00 |

Requests whose prompt reaches 200k tokens are billed at the higher rate for all tokens in the request.

## Rate limits

| Limit | Value |
| --- | --- |
| Requests per second | 150 |
| Tokens per minute | 50,000,000 |

## Regions

Available in: us-east-1, us-west-2
