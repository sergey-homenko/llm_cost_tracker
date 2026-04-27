# Parser Repair Agent Instructions

This repository is `llm_cost_tracker`, a Rails Engine gem that ledgers LLM API calls. Follow these hard project rules:

- **No code comments of any kind, ever.** Not YARD, not file-top summaries, not "why" narration. Method and identifier names carry intent. Every comment is a regression.
- **`bin/check` must pass before pushing**: zero rubocop offences, full RSpec suite green.
- **No CHANGELOG entries** for internal maintenance work like parser fixes.
- **Provider-agnostic core**: features are modeled around durable billing concepts, never around one provider's API shape.

## Project Structure

- `lib/` is gem code shipped to end users.
- `app/` is engine views, controllers, services, helpers for the mounted dashboard.
- `spec/` is RSpec tests against `spec/dummy` SQLite app.
- `scripts/` is maintainer-only tooling for price scrapers and is excluded from the gem build via `gemspec`.
- `.github/workflows/` contains CI workflows including the daily price refresh.

## Parser-Broken Issues

When an issue is labeled `parser-broken` with a `provider:<name>` label, the daily price-scrape workflow could not parse the upstream provider pricing page. Repair the parser so the next run succeeds.

1. Identify the failing provider from the `Provider: <name>` line in the issue body, the `provider:<name>` label, or the issue title.
2. Files involved:
   - Parser: `scripts/price_scrape/providers/<name>.rb`
   - Fixture: `spec/fixtures/scrape/<name>_pricing.html`
   - Spec: `spec/scripts/price_scrape/providers/<name>_spec.rb`
3. The workflow refreshes the fixture before running the agent. Inspect what changed between the old fixture and the refreshed fixture: table headers, cell formatting, model name conventions, deprecation markers.
4. Diagnose whether the failure is an upstream HTML change or a local regression:
   - Inspect the failing line and nearby git history before changing parser structure.
   - If the failure is caused by an obvious local regression, such as a selector or identifier containing `broken`, revert that regression with the smallest possible change.
   - Do not rewrite, harden, or generalize adjacent parsing logic unless the refreshed fixture proves the upstream page actually changed in that area.
   - Prefer a one-line fix over a structural rewrite when it restores the previous working behavior.
5. Adjust the provider parser only as much as the diagnosis requires:
   - Match tables by header substring, never by table index.
   - Match columns by header substring, never by cell position.
   - `normalize_model_id` returns nil for unrecognised name patterns; do not add catch-all fallbacks that silently accept unknown names.
   - Keep `MIN_MODELS_EXPECTED` and `MAX_PRICE_PER_MTOK` sanity gates intact.
   - Preserve the structural pattern of the parser; do not refactor unrelated methods.
   - Do not introduce new dependencies. Nokogiri is already available as a dev dependency.
6. Update the spec only if exact prices in the happy-path test changed because upstream values changed. Keep failure-mode tests intact. Do not delete tests to make them pass.
7. Verify:
   - `bin/check`
   - `PROVIDERS=<name> DRY_RUN=1 bundle exec ruby scripts/price_scrape/runner.rb`
8. Open a PR:
   - Title: `fix(prices): <name> parser HTML structure change`
   - Body: briefly describe what changed upstream, how the parser was adjusted, include verification commands, and link the original issue with `Closes #<number>`.

## Stop Conditions

Stop and comment on the issue instead of opening a PR if any of these are true:

- The upstream page has fundamentally changed shape: no longer table-based, requires authentication, returns persistent 4xx/5xx, or switched to client-side JS rendering with no server HTML.
- `bin/check` cannot pass after a reasonable attempt.
- The fix would require modifying files outside `scripts/price_scrape/providers/<name>.rb`, the corresponding fixture, and the corresponding spec.
- The shared infrastructure in `fetcher.rb`, `orchestrator.rb`, or `runner.rb` appears to need changes.

A clear "I cannot fix this autonomously, here is what I found" issue comment is better than a speculative PR.
