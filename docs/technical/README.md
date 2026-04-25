# Technical Documentation

These files describe the internal module boundaries for LLM Cost Tracker.

- [Module map](module-map.md)
- [Data flow](data-flow.md)
- [Extension points](extension-points.md)
- [Operational notes](operational-notes.md)

The main rule is simple: provider-specific API shapes stop at ingestion and price-source boundaries. The ledger, storage, budgets, dashboard, and reports work with canonical billing concepts.
