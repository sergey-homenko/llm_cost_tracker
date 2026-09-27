# Pricing

### Text API Pricing

| Model | Context | Input / 1M tokens | Cached input / 1M tokens | Output / 1M tokens |
| --- | --- | --- | --- | --- |
| grok-4.7 (< 200k prompt tokens) | 500k | $2.00 | $0.50 | $6.00 |
| grok-4.7 (≥ 200k prompt tokens) | 500k | $4.00 | $1.00 | $12.00 |
| grok-4.6 (< 200k prompt tokens) | 500k | $2.00 | $0.50 | $6.00 |
| grok-4.6 (≥ 200k prompt tokens) | 500k | $4.00 | $1.00 | $12.00 |
| grok-4.5 (< 200k prompt tokens) | 500k | $2.00 | $0.30 | $6.00 |
| grok-4.5 (≥ 200k prompt tokens) | 500k | $4.00 | $0.60 | $12.00 |
| grok-4.3 (< 200k prompt tokens) | 1M | $1.25 | $0.20 | $2.50 |
| grok-4.3 (≥ 200k prompt tokens) | 1M | $2.50 | $0.40 | $5.00 |
| grok-4.20-0309-reasoning (< 200k prompt tokens) | 1M | $1.25 | $0.20 | $2.50 |
| grok-4.20-0309-reasoning (≥ 200k prompt tokens) | 1M | $2.50 | $0.40 | $5.00 |
| grok-4.20-0309-non-reasoning (< 200k prompt tokens) | 1M | $1.25 | $0.20 | $2.50 |
| grok-4.20-0309-non-reasoning (≥ 200k prompt tokens) | 1M | $2.50 | $0.40 | $5.00 |
| grok-build-0.1 (< 200k prompt tokens) | 256k | $1.00 | $0.20 | $2.00 |
| grok-build-0.1 (≥ 200k prompt tokens) | 256k | $2.00 | $0.40 | $4.00 |
| grok-4.20-multi-agent-0309 (< 200k prompt tokens) | 1M | $1.25 | $0.20 | $2.50 |
| grok-4.20-multi-agent-0309 (≥ 200k prompt tokens) | 1M | $2.50 | $0.40 | $5.00 |

*Prices shown per million tokens. Models listed with two rows use long context pricing: requests whose prompt reaches the listed token threshold are billed at the higher rate for all tokens in the request.*

## Batch API Pricing

The [Batch API](/developers/advanced-api-usage/batch-api) lets you process large volumes of requests asynchronously at a discount to standard pricing. The size of the discount varies by model. Batch requests are queued and processed in the background, with most completing within 24 hours.

| | Real-time API | Batch API |
|---|---|---|
| Token pricing | Standard rates | Discounted rates (varies by model) |
| Response time | Immediate (seconds) | Typically within 24 hours |
| Rate limits | Per-minute limits apply | Requests don't count towards rate limits |

The batch discount applies to all token types — input tokens, output tokens, cached tokens, and reasoning tokens. Batch discounts by model:

**20% off standard rates**

- grok-4.3
- grok-4.20-0309-reasoning
- grok-4.20-0309-non-reasoning
- grok-4.20-multi-agent-0309

Models not listed above have no batch discount.

To see a model's resulting batch prices, toggle **"Show batch API pricing"** on its detail page. Models that accept Batch with no discount show N/A.

> [!NOTE]
>
> The batch discount applies to text and language models only. Image and video generation are supported in the Batch API but are billed at standard rates. See [Batch API documentation](/developers/advanced-api-usage/batch-api) for full details.

## Priority Processing Pricing

[Priority Processing](/developers/advanced-api-usage/priority-processing) gives text requests higher scheduling priority for lower latency. Priority requests are billed at a **2x** premium over standard rates.

| | Standard | Priority |
|---|---|---|
| Token pricing | Standard rates | **2x** standard rates |
| Response time | Standard scheduling priority | Higher scheduling priority |

The 2x multiplier applies to all token types — input, output, cached, and reasoning. [Prompt caching](/developers/advanced-api-usage/prompt-caching) discounts are applied before the multiplier.

You are only billed at the priority rate when the response confirms `"service_tier": "priority"`. If the request is served at the default tier instead, standard rates apply.

> [!NOTE]
>
> Priority Processing is available for Chat Completions and Responses endpoints only. It is not supported for image generation, video generation, or [Batch API](/developers/advanced-api-usage/batch-api) requests. See [Priority Processing documentation](/developers/advanced-api-usage/priority-processing) for full details.

## US Regional Endpoint Pricing

Requests sent to the [US regional endpoint](/developers/advanced-api-usage/regions), `https://us.api.x.ai/v1`, run inference in the United States; their token usage is billed at **1.1x** the global token rates, a 10% premium.

| | Global endpoint | US regional endpoint |
|---|---|---|
| Base URL | `https://api.x.ai/v1` | `https://us.api.x.ai/v1` |
| Token pricing | Standard rates | **1.1x** standard rates |
| Models | All models available to your team | Currently `grok-4.7` and `grok-4.6` only |

For `grok-4.7` this is $2.20 / $0.55 / $6.60 per 1M tokens (input / cached input / output) below 200k prompt tokens, and $4.40 / $1.10 / $13.20 above. The 1.1x multiplier applies to input, output, and cached input tokens, including long-context rates. [Prompt caching](/developers/advanced-api-usage/prompt-caching) discounts are applied before the multiplier. See the [Regional Endpoints documentation](/developers/advanced-api-usage/regions) for the scope of the US processing and storage guarantee.
