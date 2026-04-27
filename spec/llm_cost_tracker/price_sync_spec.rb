# frozen_string_literal: true

require "json"
require "spec_helper"
require "tempfile"
require "yaml"

class CuratedPriceFetcher
  attr_reader :requested_etag

  def initialize(response)
    @response = response
  end

  def get(_url, etag: nil)
    @requested_etag = etag
    @response
  end
end

RSpec.describe LlmCostTracker::PriceSync do
  let(:source_url) { "https://example.com/llm_cost_tracker/prices.json" }
  let(:remote_registry) do
    {
      "metadata" => {
        "schema_version" => 1,
        "min_gem_version" => "0.0.1",
        "updated_at" => "2026-04-25",
        "currency" => "USD",
        "unit" => "1M tokens"
      },
      "models" => {
        "gpt-4o" => { "input" => 2.5, "cache_read_input" => 1.25, "output" => 10.0 },
        "gpt-5-mini" => { "input" => 0.25, "cache_read_input" => 0.025, "output" => 2.0 }
      }
    }
  end

  def response(body:, etag: "snapshot-v1", not_modified: false)
    LlmCostTracker::PriceSync::Fetcher::Response.new(
      body: body,
      etag: etag,
      last_modified: nil,
      not_modified: not_modified,
      fetched_at: "2026-04-25T12:00:00Z"
    )
  end

  describe ".configured_output_path" do
    it "prefers OUTPUT over configured prices_file" do
      config = double(prices_file: "config/custom_prices.yml")

      expect(described_class.configured_output_path(env: { "OUTPUT" => "tmp/prices.yml" }, config: config)).to eq(
        "tmp/prices.yml"
      )
    end

    it "falls back to configured prices_file" do
      config = double(prices_file: "config/custom_prices.yml")

      expect(described_class.configured_output_path(env: {}, config: config)).to eq("config/custom_prices.yml")
    end

    it "uses the conventional local prices path when no output is configured" do
      config = double(prices_file: nil)

      expect(described_class.configured_output_path(env: {}, config: config)).to end_with(
        "config/llm_cost_tracker_prices.yml"
      )
    end
  end

  describe ".configured_remote_url" do
    it "uses URL when provided" do
      expect(described_class.configured_remote_url(env: { "URL" => source_url })).to eq(source_url)
    end

    it "defaults to the maintained repository snapshot" do
      expect(described_class.configured_remote_url).to include("llm_cost_tracker/main/lib/llm_cost_tracker/prices.json")
    end
  end

  describe ".refresh" do
    it "writes the curated remote snapshot and reports price changes" do
      Tempfile.create(["llm-prices", ".yml"]) do |file|
        file.write(
          {
            "metadata" => { "source_version" => "old-snapshot" },
            "models" => { "gpt-4o" => { "input" => 5.0, "output" => 15.0 } }
          }.to_yaml
        )
        file.close

        result = described_class.refresh(
          path: file.path,
          url: source_url,
          fetcher: CuratedPriceFetcher.new(response(body: JSON.generate(remote_registry)))
        )
        written = YAML.safe_load_file(file.path, aliases: false)

        expect(result.written).to be(true)
        expect(result.not_modified).to be(false)
        expect(result.changes.fetch("gpt-4o")).to eq(
          "cache_read_input" => { "from" => nil, "to" => 1.25 },
          "input" => { "from" => 5.0, "to" => 2.5 },
          "output" => { "from" => 15.0, "to" => 10.0 }
        )
        expect(written.dig("metadata", "source_url")).to eq(source_url)
        expect(written.dig("metadata", "source_version")).to eq("snapshot-v1")
        expect(written.dig("models", "gpt-5-mini", "output")).to eq(2.0)
      end
    end

    it "does not write when previewing" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        original = JSON.generate("metadata" => {}, "models" => {})
        file.write(original)
        file.close

        result = described_class.refresh(
          path: file.path,
          url: source_url,
          preview: true,
          fetcher: CuratedPriceFetcher.new(response(body: JSON.generate(remote_registry)))
        )

        expect(result.written).to be(false)
        expect(File.read(file.path)).to eq(original)
      end
    end

    it "uses the existing source version as the conditional request etag" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(JSON.generate("metadata" => { "source_version" => "snapshot-v1" }, "models" => {}))
        file.close

        fetcher = CuratedPriceFetcher.new(response(body: nil, not_modified: true))
        result = described_class.refresh(path: file.path, url: source_url, fetcher: fetcher)

        expect(fetcher.requested_etag).to eq("snapshot-v1")
        expect(result.not_modified).to be(true)
        expect(result.written).to be(false)
      end
    end

    it "rejects oversized local registries before refreshing" do
      stub_const("LlmCostTracker::PriceSync::RegistryLoader::MAX_FILE_BYTES", 10)

      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(JSON.generate("metadata" => {}, "models" => {}))
        file.close

        expect do
          described_class.refresh(
            path: file.path,
            url: source_url,
            fetcher: CuratedPriceFetcher.new(response(body: JSON.generate(remote_registry)))
          )
        end.to raise_error(LlmCostTracker::Error, /pricing registry exceeds/)
      end
    end

    it "leaves the existing file untouched when the remote schema is too new" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        original = JSON.generate("metadata" => {}, "models" => {})
        file.write(original)
        file.close
        registry = remote_registry.merge("metadata" => remote_registry.fetch("metadata").merge("schema_version" => 99))

        expect do
          described_class.refresh(
            path: file.path,
            url: source_url,
            fetcher: CuratedPriceFetcher.new(response(body: JSON.generate(registry)))
          )
        end.to raise_error(LlmCostTracker::Error, /schema_version=99/)
        expect(File.read(file.path)).to eq(original)
      end
    end

    it "rejects invalid remote schema metadata" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        original = JSON.generate("metadata" => {}, "models" => {})
        file.write(original)
        file.close
        registry = remote_registry.merge("metadata" => remote_registry.fetch("metadata").merge("schema_version" => nil))

        expect do
          described_class.refresh(
            path: file.path,
            url: source_url,
            fetcher: CuratedPriceFetcher.new(response(body: JSON.generate(registry)))
          )
        end.to raise_error(LlmCostTracker::Error, /Unable to load remote pricing snapshot/)
        expect(File.read(file.path)).to eq(original)
      end
    end

    it "leaves the existing file untouched when the snapshot requires a newer gem" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        original = JSON.generate("metadata" => {}, "models" => {})
        file.write(original)
        file.close
        registry = remote_registry.merge(
          "metadata" => remote_registry.fetch("metadata").merge("min_gem_version" => "99.0.0")
        )

        expect do
          described_class.refresh(
            path: file.path,
            url: source_url,
            fetcher: CuratedPriceFetcher.new(response(body: JSON.generate(registry)))
          )
        end.to raise_error(LlmCostTracker::Error, /requires llm_cost_tracker >= 99.0.0/)
        expect(File.read(file.path)).to eq(original)
      end
    end
  end

  describe ".check" do
    it "reports drift without writing" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        original = JSON.generate(
          "metadata" => {},
          "models" => { "gpt-4o" => { "input" => 5.0, "output" => 15.0 } }
        )
        file.write(original)
        file.close

        result = described_class.check(
          path: file.path,
          url: source_url,
          fetcher: CuratedPriceFetcher.new(response(body: JSON.generate(remote_registry)))
        )

        expect(result.up_to_date).to be(false)
        expect(result.changes.keys).to include("gpt-4o", "gpt-5-mini")
        expect(File.read(file.path)).to eq(original)
      end
    end

    it "reports up-to-date on a not-modified response" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(JSON.generate("metadata" => { "source_version" => "snapshot-v1" }, "models" => {}))
        file.close

        result = described_class.check(
          path: file.path,
          url: source_url,
          fetcher: CuratedPriceFetcher.new(response(body: nil, not_modified: true))
        )

        expect(result.up_to_date).to be(true)
        expect(result.changes).to eq({})
      end
    end
  end
end
