# Extending LLM Cost Tracker

Extensions belong at clear boundaries: parsers for response shapes, integrations
for SDK hooks, pricing files for rates, and custom storage for apps that own
persistence themselves.

The practical extension guide is moving here from the README. The lower-level
contracts already live in the technical extension reference.

## Canonical Sources

Until this page is expanded, use:

- [Capturing calls](../README.md#capturing-calls)
- [Pricing](pricing.md)
- [Technical extension points](technical/extension-points.md)

## Extension Points

- Custom parser: translate a provider response into `ParsedUsage`.
- OpenAI-compatible host: register the host-to-provider mapping.
- Custom storage: receive the canonical `Event` and write it elsewhere.
- Notifications subscriber: observe `llm_request.llm_cost_tracker`.
- Local price file: model gateway IDs, contract rates, or unsupported models.

## Parser Boundary

A parser matches request URLs, translates provider response shapes into
`ParsedUsage`, and returns `nil` when the response is outside its contract.

Do provider-specific translation at this boundary. Keep `Tracker`, storage,
dashboard, and pricing in canonical ledger terms.
