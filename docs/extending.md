# Extending LLM Cost Tracker

Extensions belong at clear boundaries: OpenAI-compatible host mappings, pricing
files for rates, notifications, and explicit tracking calls for unsupported
response shapes.

The practical extension guide is moving here from the README. The lower-level
contracts already live in the technical extension reference.

## Canonical Sources

Until this page is expanded, use:

- [Capturing calls](../README.md#capturing-calls)
- [Pricing](pricing.md)
- [Technical extension points](technical/extension-points.md)

## Extension Points

- OpenAI-compatible host: register the host-to-provider mapping.
- Notifications subscriber: observe `llm_request.llm_cost_tracker`.
- Local price file: model gateway IDs, contract rates, or unsupported models.
- Explicit tracking: call `LlmCostTracker.track` / `track_stream` when a provider response shape is not built in.

## Provider Boundary

Built-in parsers match supported request URLs, translate known provider response
shapes into `ParsedUsage`, and return `nil` when the response is outside their
contract.

Keep provider-specific translation outside storage, dashboard, and pricing. Use
canonical ledger terms when calling `track` directly.
