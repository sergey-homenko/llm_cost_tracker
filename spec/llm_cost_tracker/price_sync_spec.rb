# frozen_string_literal: true

require "json"
require "spec_helper"
require "tempfile"
require "tmpdir"

class PriceSyncFixtureFetcher
  def initialize(fixtures:, failures: {})
    @fixtures = fixtures
    @failures = failures
  end

  def get(url, etag: nil)
    raise LlmCostTracker::Error, @failures.fetch(url) if @failures.key?(url)

    fixture = @fixtures.fetch(url)
    LlmCostTracker::PriceSync::Fetcher::Response.new(
      body: fixture.fetch(:body),
      etag: fixture[:etag] || etag,
      last_modified: fixture[:last_modified],
      not_modified: false,
      fetched_at: fixture.fetch(:fetched_at)
    )
  end
end

RSpec.describe LlmCostTracker::PriceSync do
  let(:today) { Date.new(2026, 4, 22) }

  let(:fixtures) do
    {
      LlmCostTracker::PriceSync::Sources::Litellm::URL => {
        body: File.read(fixture_path("litellm_snapshot_2026-04-22.json")),
        etag: "litellm-fixture-v1",
        fetched_at: "2026-04-22T00:00:00Z"
      },
      LlmCostTracker::PriceSync::Sources::OpenRouter::URL => {
        body: File.read(fixture_path("openrouter_snapshot_2026-04-22.json")),
        etag: "openrouter-fixture-v1",
        fetched_at: "2026-04-22T00:00:00Z"
      }
    }
  end

  let(:fetcher) { PriceSyncFixtureFetcher.new(fixtures: fixtures) }

  let(:seed_registry) do
    {
      "metadata" => {
        "updated_at" => "2026-04-18",
        "currency" => "USD",
        "unit" => "1M tokens"
      },
      "models" => {
        "gpt-4o" => { "input" => 9.0, "cached_input" => 4.5, "output" => 11.0, "_notes" => "keep me" },
        "gpt-4o-2024-05-13" => { "input" => 5.0, "output" => 15.0 },
        "gpt-4o-mini" => { "input" => 0.2, "output" => 0.8 },
        "claude-sonnet-4-6" => {
          "input" => 2.0,
          "cache_read_input" => 0.2,
          "cache_creation_input" => 2.5,
          "output" => 10.0
        },
        "gemini-2.5-flash" => { "input" => 0.2, "output" => 2.0 },
        "gemini-1.5-pro" => { "input" => 0.9, "output" => 4.5 },
        "custom-gateway-model" => {
          "input" => 0.7,
          "output" => 0.9,
          "_source" => "manual",
          "_notes" => "leave me"
        },
        "legacy-orphan-model" => { "input" => 1.2, "output" => 1.5 }
      }
    }
  end

  describe ".sync" do
    it "writes the expected registry snapshot from structured JSON sources" do
      Tempfile.create(["price-sync", ".json"]) do |file|
        file.write(JSON.pretty_generate(seed_registry))
        file.close

        result = described_class.sync(path: file.path, fetcher: fetcher, today: today)
        expected = JSON.parse(File.read(fixture_path("expected_prices_after_sync.json")))
        actual = JSON.parse(File.read(file.path))

        expect(result.updated_models).to eq(
          %w[claude-sonnet-4-6 gemini-2.5-flash gpt-4o gpt-4o-2024-05-13 gpt-4o-mini]
        )
        expect(result.orphaned_models).to eq(%w[gemini-1.5-pro legacy-orphan-model])
        expect(result.failed_sources).to eq({})
        expect(result.discrepancies.map { |issue| [issue.model, issue.field] }).to eq([%w[gpt-4o-mini output]])
        expect(result.sources_used.fetch(:litellm).source_version).to eq("litellm-fixture-v1")
        expect(result.sources_used.fetch(:openrouter).source_version).to eq("openrouter-fixture-v1")
        expect(result.written).to be(true)
        expect(actual).to eq(expected)
      end
    end

    it "supports previews without writing the file" do
      Tempfile.create(["price-sync", ".json"]) do |file|
        original_contents = JSON.pretty_generate(seed_registry)
        file.write(original_contents)
        file.close

        result = described_class.sync(path: file.path, fetcher: fetcher, today: today, preview: true)

        expect(result.written).to be(false)
        expect(result.updated_models).not_to be_empty
        expect(File.read(file.path)).to eq(original_contents)
      end
    end

    it "falls back to secondary JSON sources when the primary source fails" do
      failing_fetcher = PriceSyncFixtureFetcher.new(
        fixtures: fixtures,
        failures: { LlmCostTracker::PriceSync::Sources::Litellm::URL => "timeout while fetching LiteLLM" }
      )

      Tempfile.create(["price-sync", ".json"]) do |file|
        file.write(JSON.pretty_generate(seed_registry))
        file.close

        result = described_class.sync(path: file.path, fetcher: failing_fetcher, today: today)
        registry = JSON.parse(File.read(file.path))

        expect(result.failed_sources).to eq(litellm: "timeout while fetching LiteLLM")
        expect(result.sources_used.keys).to eq([:openrouter])
        expect(registry.dig("models", "gpt-4o", "_source")).to eq("openrouter")
        expect(registry.dig("metadata", "source_urls")).to eq([LlmCostTracker::PriceSync::Sources::OpenRouter::URL])
        expect(registry.dig("models", "gpt-4o-mini", "output")).to eq(0.63)
        expect(registry.dig("models", "claude-sonnet-4-6", "cache_creation_input")).to eq(3.75)
        expect(registry.dig("models", "custom-gateway-model", "_source")).to eq("manual")
      end
    end

    it "raises in strict mode and leaves the existing file untouched on source failures" do
      failing_fetcher = PriceSyncFixtureFetcher.new(
        fixtures: fixtures,
        failures: { LlmCostTracker::PriceSync::Sources::Litellm::URL => "timeout while fetching LiteLLM" }
      )

      Tempfile.create(["price-sync", ".json"]) do |file|
        original_contents = JSON.pretty_generate(seed_registry)
        file.write(original_contents)
        file.close

        expect do
          described_class.sync(path: file.path, fetcher: failing_fetcher, today: today, strict: true)
        end.to raise_error(LlmCostTracker::Error, /Price sync failed in strict mode: source failures:/)

        expect(File.read(file.path)).to eq(original_contents)
      end
    end

    it "does not write anything when every JSON source fails" do
      failing_fetcher = PriceSyncFixtureFetcher.new(
        fixtures: fixtures,
        failures: fixtures.keys.to_h { |url| [url, "unavailable: #{url}"] }
      )

      Dir.mktmpdir do |dir|
        output_path = File.join(dir, "llm_cost_tracker_prices.json")
        seed_path = File.join(dir, "seed_prices.json")
        File.write(seed_path, JSON.pretty_generate(seed_registry))

        result = described_class.sync(
          path: output_path,
          seed_path: seed_path,
          fetcher: failing_fetcher,
          today: today
        )

        expect(result.written).to be(false)
        expect(result.failed_sources.keys).to contain_exactly(:litellm, :openrouter)
        expect(File.exist?(output_path)).to be(false)
      end
    end

    it "keeps the file untouched when sources return no matching models" do
      Tempfile.create(["price-sync", ".json"]) do |file|
        registry = {
          "metadata" => {
            "updated_at" => "2026-04-18",
            "currency" => "USD",
            "unit" => "1M tokens"
          },
          "models" => {
            "my-private-model" => { "input" => 1.0, "output" => 2.0, "_source" => "manual" }
          }
        }
        original_contents = JSON.pretty_generate(registry)
        file.write(original_contents)
        file.close

        result = described_class.sync(path: file.path, fetcher: fetcher, today: today)

        expect(result.written).to be(false)
        expect(result.updated_models).to eq([])
        expect(File.read(file.path)).to eq(original_contents)
      end
    end
  end

  describe ".check" do
    it "returns detailed price changes without writing the file" do
      Tempfile.create(["price-sync", ".json"]) do |file|
        original_contents = JSON.pretty_generate(seed_registry)
        file.write(original_contents)
        file.close

        result = described_class.check(path: file.path, fetcher: fetcher, today: today)

        expect(result.up_to_date).to be(false)
        expect(result.failed_sources).to eq({})
        expect(result.orphaned_models).to eq(%w[gemini-1.5-pro legacy-orphan-model])
        expect(result.discrepancies.map { |issue| [issue.model, issue.field] }).to eq([%w[gpt-4o-mini output]])
        expect(result.changes.fetch("gpt-4o")).to eq(
          "cached_input" => { "from" => 4.5, "to" => 1.25 },
          "input" => { "from" => 9.0, "to" => 2.5 },
          "output" => { "from" => 11.0, "to" => 10.0 }
        )
        expect(result.changes.fetch("gpt-4o-mini")).to eq(
          "cached_input" => { "from" => nil, "to" => 0.075 },
          "input" => { "from" => 0.2, "to" => 0.15 },
          "output" => { "from" => 0.8, "to" => 0.6 }
        )
        expect(File.read(file.path)).to eq(original_contents)
      end
    end

    it "reports up-to-date when the snapshot already matches the synced output" do
      Tempfile.create(["price-sync", ".json"]) do |file|
        file.write(JSON.pretty_generate(seed_registry))
        file.close

        described_class.sync(path: file.path, fetcher: fetcher, today: today)
        result = described_class.check(path: file.path, fetcher: fetcher, today: today)

        expect(result.up_to_date).to be(true)
        expect(result.changes).to eq({})
        expect(result.discrepancies.map { |issue| [issue.model, issue.field] }).to eq([%w[gpt-4o-mini output]])
      end
    end
  end

  def fixture_path(name)
    File.expand_path("../fixtures/pricing/#{name}", __dir__)
  end
end
