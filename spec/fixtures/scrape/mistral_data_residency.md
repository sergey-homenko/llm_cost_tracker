# Regional inference

:::info
Regional inference is billed at **1.1× standard list pricing** (a 10% upcharge) for input tokens, output tokens, cached reads, and cache writes.
:::

| Endpoint | Region | Regional upcharge | Geography | When to use it |
|---|---|---|---|---|
| [`api.mistral.ai`](https://api.mistral.ai) | Global | No | Not region-specific | Use the global endpoint when you do not need a specific inference location. Mistral does not commit to a specific inference location for requests sent to this endpoint. |
| [`api.eu.mistral.ai`](https://api.eu.mistral.ai) | EU | Yes | Multiple data centers in EU and EFTA countries | Use the EU regional endpoint to support inference processing within the European Union. |
| [`api.us.mistral.ai`](https://api.us.mistral.ai) | US | Yes | Multiple data centers in the United States | Use the US regional endpoint to support inference processing within the United States. |
