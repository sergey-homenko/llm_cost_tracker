# frozen_string_literal: true

require "spec_helper"
require "json"
require "tempfile"
require "price_scrape/orchestrator"

RSpec.describe LlmCostTracker::PriceScrape::Orchestrator do
  let(:provider_result_class) do
    Data.define(:source_url, :scraped_at, :models, :deprecated_models)
  end

  def build_result(models:, deprecated_models: [])
    provider_result_class.new(
      source_url: "https://example.com/pricing",
      scraped_at: "2026-04-26T00:00:00Z",
      models: models,
      deprecated_models: deprecated_models
    )
  end

  def build_registry(models:, metadata: {})
    {
      "metadata" => { "schema_version" => 1, "updated_at" => "2026-04-01" }.merge(metadata),
      "models" => models
    }
  end

  def with_registry(registry)
    Tempfile.create(["registry", ".json"]) do |file|
      file.write(JSON.pretty_generate(registry))
      file.close
      yield file.path
    end
  end

  it "adds active models that are not yet in the registry" do
    registry = build_registry(models: { "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } })
    provider_result = build_result(
      models: {
        "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 },
        "claude-haiku-4-5" => { "input" => 1.0, "output" => 5.0 }
      }
    )

    with_registry(registry) do |path|
      result = described_class.new(today: Date.new(2026, 4, 26)).call(
        provider_result: provider_result,
        registry_path: path
      )

      expect(result.added).to eq(["claude-haiku-4-5"])
      expect(result.removed).to eq([])
      expect(result.updated).to eq({})
      expect(result.written).to be(true)

      written = JSON.parse(File.read(path))
      expect(written.dig("models", "claude-haiku-4-5")).to eq("input" => 1.0, "output" => 5.0)
      expect(written.dig("metadata", "updated_at")).to eq("2026-04-26")
    end
  end

  it "removes deprecated models that are still in the registry" do
    registry = build_registry(models: {
                                "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 },
                                "claude-sonnet-3-7" => { "input" => 3.0, "output" => 15.0 }
                              })
    provider_result = build_result(
      models: {
        "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 },
        "claude-sonnet-3-7" => { "input" => 3.0, "output" => 15.0 }
      },
      deprecated_models: ["claude-sonnet-3-7"]
    )

    with_registry(registry) do |path|
      result = described_class.new(today: Date.new(2026, 4, 26)).call(
        provider_result: provider_result,
        registry_path: path
      )

      expect(result.removed).to eq(["claude-sonnet-3-7"])
      expect(JSON.parse(File.read(path)).fetch("models")).not_to have_key("claude-sonnet-3-7")
    end
  end

  it "updates only changed price fields and preserves unrelated metadata fields" do
    registry = build_registry(models: {
                                "claude-opus-4-7" => {
                                  "input" => 5.0,
                                  "output" => 25.0,
                                  "_source" => "manual"
                                }
                              })
    provider_result = build_result(
      models: {
        "claude-opus-4-7" => {
          "input" => 5.0,
          "output" => 25.0,
          "batch_input" => 2.5,
          "batch_output" => 12.5
        }
      }
    )

    with_registry(registry) do |path|
      result = described_class.new.call(provider_result: provider_result, registry_path: path)

      expect(result.updated).to eq(
        "claude-opus-4-7" => {
          "batch_input" => { "from" => nil, "to" => 2.5 },
          "batch_output" => { "from" => nil, "to" => 12.5 }
        }
      )
      written = JSON.parse(File.read(path))
      expect(written.dig("models", "claude-opus-4-7")).to eq(
        "input" => 5.0,
        "output" => 25.0,
        "_source" => "manual",
        "batch_input" => 2.5,
        "batch_output" => 12.5
      )
    end
  end

  it "leaves models from other providers in the registry untouched" do
    registry = build_registry(models: {
                                "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 },
                                "gpt-4o" => { "input" => 2.5, "output" => 10.0 },
                                "gemini-2.5-flash" => { "input" => 0.3, "output" => 2.5 }
                              })
    provider_result = build_result(
      models: { "claude-opus-4-7" => { "input" => 6.0, "output" => 25.0 } }
    )

    with_registry(registry) do |path|
      described_class.new.call(provider_result: provider_result, registry_path: path)

      models = JSON.parse(File.read(path)).fetch("models")
      expect(models["gpt-4o"]).to eq("input" => 2.5, "output" => 10.0)
      expect(models["gemini-2.5-flash"]).to eq("input" => 0.3, "output" => 2.5)
      expect(models["claude-opus-4-7"]).to eq("input" => 6.0, "output" => 25.0)
    end
  end

  it "does not write when nothing changed" do
    registry = build_registry(models: { "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } })
    provider_result = build_result(
      models: { "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } }
    )

    with_registry(registry) do |path|
      original_mtime = File.mtime(path)
      sleep 0.01
      result = described_class.new.call(provider_result: provider_result, registry_path: path)

      expect(result.changed?).to be(false)
      expect(result.written).to be(false)
      expect(File.mtime(path)).to eq(original_mtime)
    end
  end

  it "does not write in dry_run mode even when there are changes" do
    registry = build_registry(models: { "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } })
    provider_result = build_result(
      models: { "claude-opus-4-7" => { "input" => 6.0, "output" => 25.0 } }
    )

    with_registry(registry) do |path|
      original = File.read(path)
      result = described_class.new(dry_run: true).call(
        provider_result: provider_result,
        registry_path: path
      )

      expect(result.changed?).to be(true)
      expect(result.written).to be(false)
      expect(File.read(path)).to eq(original)
    end
  end
end
