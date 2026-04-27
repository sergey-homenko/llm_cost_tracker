# GitHub Copilot Coding Agent instructions

This repository is `llm_cost_tracker`, a Rails Engine gem that ledgers LLM API calls. Follow these hard project rules:

- **No code comments of any kind, ever.** Not YARD, not file-top summaries, not "why" narration. Method and identifier names carry intent. Every comment is a regression.
- **`bin/check` must pass before pushing**: zero rubocop offences, full RSpec suite green.
- **No CHANGELOG entries** for internal maintenance work (like parser fixes).
- **Provider-agnostic core**: features modeled around durable billing concepts, never around one provider's API shape.

## Project structure

- `lib/` — gem code shipped to end users
- `app/` — engine views, controllers, services, helpers for the mounted dashboard
- `spec/` — RSpec tests (against `spec/dummy` SQLite app)
- `scripts/` — maintainer-only tooling (price scrapers); excluded from the gem build via `gemspec`
- `.github/workflows/` — CI workflows including the daily price refresh

## Most common task: fix a `parser-broken` issue

When an issue is labeled `parser-broken` with a `provider:<name>` label (e.g. `provider:gemini`), it means the daily price-scrape workflow could not parse the upstream provider pricing page. Your job is to repair the parser so the next run succeeds.

### Fix workflow

1. **Identify the failing provider** from the `Provider: <name>` line in the issue body or the `provider:<name>` label. Files involved:
   - Parser: `scripts/price_scrape/providers/<name>.rb`
   - Fixture: `spec/fixtures/scrape/<name>_pricing.html`
   - Spec: `spec/scripts/price_scrape/providers/<name>_spec.rb`

2. **Refresh the fixture** with the current upstream HTML. Read `SOURCE_URL` from the parser file:
   ```bash
   curl -sL -A "llm_cost_tracker price scrape" \
     <SOURCE_URL value> \
     -o spec/fixtures/scrape/<name>_pricing.html
   ```

3. **Inspect what changed** between the old fixture (in git history) and the new one. Look at table headers, cell formatting, model name conventions, deprecation markers.

4. **Adjust the parser** in `scripts/price_scrape/providers/<name>.rb`:
   - Match tables by header substring, never by table index.
   - Match columns by header substring, never by cell position.
   - `normalize_model_id` returns nil for unrecognised name patterns; do not add catch-all fallbacks that silently accept unknown names.
   - Keep `MIN_MODELS_EXPECTED` and `MAX_PRICE_PER_MTOK` sanity gates intact.
   - Preserve the structural pattern of the parser; do not refactor unrelated methods.
   - Do not introduce new dependencies. Nokogiri is already available as a dev dep.

5. **Update the spec** only if exact prices in the happy-path test changed because the upstream values changed. Keep the same set of failure-mode tests intact. Do not delete tests to make them pass.

6. **Verify locally before committing**:
   ```bash
   bin/check
   PROVIDERS=<name> DRY_RUN=1 bundle exec ruby scripts/price_scrape/runner.rb
   ```
   `bin/check` must show zero rubocop offences and a fully green RSpec run. The runner must print `[<name>] parsed N models` with N at least `MIN_MODELS_EXPECTED`, and no `FAILED:` line.

7. **Commit and open the PR**:
   - Title: `fix(prices): <name> parser HTML structure change`
   - Body: brief plain-English description of what changed upstream and how the parser was adjusted; link the original issue with `Closes #<number>`.

### When to NOT open a PR

Stop and comment on the issue instead if any of these are true:

- The upstream page has fundamentally changed shape (no longer table-based, requires authentication, returns persistent 4xx/5xx, switched to client-side JS rendering with no server HTML).
- You cannot get `bin/check` to pass after a reasonable attempt.
- The fix would require modifying files outside `scripts/price_scrape/providers/<name>.rb`, the corresponding fixture, and the corresponding spec. The shared infrastructure (`fetcher.rb`, `orchestrator.rb`, `runner.rb`) is provider-agnostic and not the right place to fix parser-specific issues.

A clear "I cannot fix this autonomously, here is what I found" comment is more valuable than a speculative PR that the maintainer has to revert.

## Hard rules for any task assigned to you

- No code comments. Re-read this if tempted.
- No new gem dependencies in `gemspec` unless the task description explicitly requires it.
- No changes to `lib/` when fixing parser-broken issues. Parsers live in `scripts/`, intentionally separated from gem code.
- No CHANGELOG entries for parser fixes — they are internal maintenance, not user-facing changes.
- `bin/check` must pass before any push.
- Confirm `git status` before committing to avoid staging unrelated changes (e.g. `bundle install` artifacts, coverage reports).
- If you find yourself wanting to refactor code outside the immediate scope of the task, stop. Comment on the issue with the observation and let a human decide.
