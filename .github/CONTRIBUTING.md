# Contributing

Thanks for your interest in improving `llm_cost_tracker`. This project is a small, focused Rails-native cost ledger — scope is intentionally narrow, so please read the **Scope** section below before proposing larger features.

## Reporting bugs

Open an issue using the **Bug report** template. Please include:

- Ruby version, Rails version, and the DB adapter (PostgreSQL / MySQL / SQLite)
- The provider(s) involved (OpenAI / Anthropic / Gemini / OpenAI-compatible)
- A minimal snippet that reproduces the problem
- What you expected vs. what happened

If the issue is about missing or wrong pricing, include the exact model string and a link to the provider's published pricing page.

## Proposing features

Open an issue using the **Feature request** template before sending a PR. Scope check first — see below.

## Scope

`llm_cost_tracker` answers one question: *what did this app spend on LLM APIs, and where did that spend come from?* It is deliberately **not** a tracing platform, prompt CMS, eval system, caching layer, or gateway.

Good feature proposals usually fit one of:

- New provider parser (Bedrock, Azure OpenAI, Vertex AI non-Gemini, Cohere, Mistral, etc.)
- Better attribution / tagging ergonomics
- Dashboard improvements (spend views, data quality signals)
- Pricing accuracy (new pricing shapes, drift detection, overrides)
- Completeness signals (gap detection, missing-usage events, parser versioning)
- Safety (PII redaction hooks, tag sanitization)

Usually out of scope:

- OpenTelemetry / Prometheus exporters (belongs in a companion gem)
- Response caching (changes semantics from observer to participant)
- Warehouse export adapters (BigQuery, Snowflake, Redshift — separate gem)
- A/B testing / eval dashboards
- Request rate limiting / throttling
- Reconciliation via provider billing APIs (requires admin credentials most users don't have)

If in doubt, open an issue first and we can discuss whether it fits.

## Development setup

```bash
git clone https://github.com/sergey-homenko/llm_cost_tracker.git
cd llm_cost_tracker
bundle install
```

### Running tests

```bash
bundle exec rspec
```

To test against a specific Rails version:

```bash
BUNDLE_GEMFILE=gemfiles/rails_8_0.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/rails_8_0.gemfile bundle exec rspec
```

The CI matrix covers Ruby 3.3 / 3.4 across Rails 7.1 / 7.2 / 8.0 / 8.1.

### Running the linter

```bash
bundle exec rubocop
```

### Checking coverage

```bash
bundle exec rspec
open coverage/index.html
```

## Pull requests

- Branch from `main`
- Keep each PR focused on one concern
- Add or update specs — features and bug fixes both need test coverage
- Update `CHANGELOG.md` under the `## [Unreleased]` section
- Update `README.md` if you're changing user-facing behavior
- Run `bundle exec rspec` and `bundle exec rubocop` before pushing
- Keep commits reasonable — squash "fix typo" / "oops" into their parent before requesting review

### Code style

- Follow the existing RuboCop config
- Prefer clear identifier names over comments
- Keep public API changes minimal and additive where possible
- When adding a new parser or storage backend, mirror the shape of the existing ones

### Migrations and DB compatibility

- Any schema change must work on PostgreSQL, MySQL, and SQLite
- Use `connection.adapter_name` to branch for PG-specific features (JSONB, GIN indexes); provide a text fallback for the others
- All migrations must be reversible

## Releasing

Releases are handled by the maintainer. If you want to suggest a release, mention it in your PR.

## Questions

For general questions, open a GitHub Discussion rather than an issue. For anything sensitive (security, conduct), email **sergey@mm.st**.
