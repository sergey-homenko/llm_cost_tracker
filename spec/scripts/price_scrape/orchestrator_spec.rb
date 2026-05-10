# frozen_string_literal: true

require "spec_helper"
require "json"
require "tempfile"
require "price_scrape/orchestrator"

RSpec.describe LlmCostTracker::Pricing::Scrape::Orchestrator do
  let(:provider_result_class) do
    Data.define(:source_url, :scraped_at, :models, :deprecated_models, :service_charges)
  end

  def build_result(models:, deprecated_models: [], service_charges: {})
    provider_result_class.new(
      source_url: "https://example.com/pricing",
      scraped_at: "2026-04-26T00:00:00Z",
      models: models,
      deprecated_models: deprecated_models,
      service_charges: service_charges
    )
  end

  def build_registry(models:, metadata: {}, service_charges: {})
    {
      "metadata" => { "schema_version" => 1, "updated_at" => "2026-04-01" }.merge(metadata),
      "service_charges" => service_charges,
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
    registry = build_registry(models: { "anthropic/claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } })
    provider_result = build_result(
      models: {
        "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 },
        "claude-haiku-4-5" => { "input" => 1.0, "output" => 5.0 }
      }
    )

    with_registry(registry) do |path|
      result = described_class.new(today: Date.new(2026, 4, 26)).call(
        provider: "anthropic",
        provider_result: provider_result,
        registry_path: path
      )

      expect(result.added).to eq(["anthropic/claude-haiku-4-5"])
      expect(result.removed).to eq([])
      expect(result.updated).to eq({})
      expect(result.written).to be(true)

      written = JSON.parse(File.read(path))
      expect(written.dig("models", "anthropic/claude-haiku-4-5")).to eq("input" => 1.0, "output" => 5.0)
      expect(written.dig("metadata", "updated_at")).to eq("2026-04-26")
    end
  end

  it "migrates legacy unqualified model keys to provider-qualified keys" do
    registry = build_registry(models: { "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } })
    provider_result = build_result(
      models: { "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0, "batch_input" => 2.5 } }
    )

    with_registry(registry) do |path|
      result = described_class.new.call(provider: "anthropic", provider_result: provider_result, registry_path: path)

      expect(result.added).to eq(["anthropic/claude-opus-4-7"])
      expect(result.removed).to eq(["claude-opus-4-7"])

      models = JSON.parse(File.read(path)).fetch("models")
      expect(models).not_to have_key("claude-opus-4-7")
      expect(models["anthropic/claude-opus-4-7"]).to eq(
        "input" => 5.0,
        "output" => 25.0,
        "batch_input" => 2.5
      )
    end
  end

  it "removes deprecated models that are still in the registry" do
    registry = build_registry(models: {
                                "anthropic/claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 },
                                "anthropic/claude-sonnet-3-7" => { "input" => 3.0, "output" => 15.0 }
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
        provider: "anthropic",
        provider_result: provider_result,
        registry_path: path
      )

      expect(result.removed).to eq(["anthropic/claude-sonnet-3-7"])
      expect(JSON.parse(File.read(path)).fetch("models")).not_to have_key("anthropic/claude-sonnet-3-7")
    end
  end

  it "replaces provider-owned price fields and preserves unrelated metadata fields" do
    registry = build_registry(models: {
                                "anthropic/claude-opus-4-7" => {
                                  "input" => 5.0,
                                  "output" => 25.0,
                                  "batch_cache_read_input" => 0.5,
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
      result = described_class.new.call(provider: "anthropic", provider_result: provider_result, registry_path: path)

      expect(result.updated).to eq(
        "anthropic/claude-opus-4-7" => {
          "batch_input" => { "from" => nil, "to" => 2.5 },
          "batch_cache_read_input" => { "from" => 0.5, "to" => nil },
          "batch_output" => { "from" => nil, "to" => 12.5 }
        }
      )
      written = JSON.parse(File.read(path))
      expect(written.dig("models", "anthropic/claude-opus-4-7")).to eq(
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
                                "anthropic/claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 },
                                "openai/gpt-4o" => { "input" => 2.5, "output" => 10.0 },
                                "gemini/gemini-2.5-flash" => { "input" => 0.3, "output" => 2.5 }
                              })
    provider_result = build_result(
      models: { "claude-opus-4-7" => { "input" => 6.0, "output" => 25.0 } }
    )

    with_registry(registry) do |path|
      described_class.new.call(provider: "anthropic", provider_result: provider_result, registry_path: path)

      models = JSON.parse(File.read(path)).fetch("models")
      expect(models["openai/gpt-4o"]).to eq("input" => 2.5, "output" => 10.0)
      expect(models["gemini/gemini-2.5-flash"]).to eq("input" => 0.3, "output" => 2.5)
      expect(models["anthropic/claude-opus-4-7"]).to eq("input" => 6.0, "output" => 25.0)
    end
  end

  it "does not write when nothing changed" do
    registry = build_registry(models: { "anthropic/claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } })
    provider_result = build_result(
      models: { "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } }
    )

    with_registry(registry) do |path|
      original_mtime = File.mtime(path)
      sleep 0.01
      result = described_class.new.call(provider: "anthropic", provider_result: provider_result, registry_path: path)

      expect(result.changed?).to be(false)
      expect(result.written).to be(false)
      expect(File.mtime(path)).to eq(original_mtime)
    end
  end

  it "does not write in dry_run mode even when there are changes" do
    registry = build_registry(models: { "anthropic/claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } })
    provider_result = build_result(
      models: { "claude-opus-4-7" => { "input" => 6.0, "output" => 25.0 } }
    )

    with_registry(registry) do |path|
      original = File.read(path)
      result = described_class.new(dry_run: true).call(
        provider: "anthropic",
        provider_result: provider_result,
        registry_path: path
      )

      expect(result.changed?).to be(true)
      expect(result.written).to be(false)
      expect(File.read(path)).to eq(original)
    end
  end

  it "merges scraped provider service charge rates with the existing catalog without touching other providers" do
    registry = build_registry(
      models: { "openai/gpt-5" => { "input" => 1.25, "output" => 10.0 } },
      service_charges: {
        "anthropic" => { "web_search_request" => 10.0 },
        "openai" => { "web_search_request" => 8.0, "priority_web_search_request" => 12.0 }
      }
    )
    provider_result = build_result(
      models: { "gpt-5" => { "input" => 1.25, "output" => 10.0 } },
      service_charges: {
        "web_search_request" => 10.0,
        "file_search_call" => 2.5
      }
    )

    with_registry(registry) do |path|
      result = described_class.new(today: Date.new(2026, 4, 26)).call(
        provider: "openai",
        provider_result: provider_result,
        registry_path: path
      )

      expect(result.service_charges_updated).to eq(
        "web_search_request" => { "from" => 8.0, "to" => 10.0 },
        "file_search_call" => { "from" => nil, "to" => 2.5 }
      )

      service_charges = JSON.parse(File.read(path)).fetch("service_charges")
      expect(service_charges.fetch("anthropic")).to eq("web_search_request" => 10.0)
      expect(service_charges.fetch("openai")).to eq(
        "web_search_request" => 10.0,
        "priority_web_search_request" => 12.0,
        "file_search_call" => 2.5
      )
    end
  end

  it "removes provider service charge rates when the scraper no longer returns any" do
    registry = build_registry(
      models: { "gemini/gemini-2.5-flash" => { "input" => 0.3, "output" => 2.5 } },
      service_charges: {
        "gemini" => { "grounding_request" => 35.0 },
        "openai" => { "web_search_request" => 10.0 }
      }
    )
    provider_result = build_result(
      models: { "gemini-2.5-flash" => { "input" => 0.3, "output" => 2.5 } },
      service_charges: {}
    )

    with_registry(registry) do |path|
      result = described_class.new.call(provider: "gemini", provider_result: provider_result, registry_path: path)

      expect(result.service_charges_updated).to be_empty

      service_charges = JSON.parse(File.read(path)).fetch("service_charges")
      expect(service_charges.fetch("gemini")).to eq("grounding_request" => 35.0)
      expect(service_charges.fetch("openai")).to eq("web_search_request" => 10.0)
    end
  end

  it "preserves manually-added service charge keys when the scraper returns a different subset" do
    registry = build_registry(
      models: { "anthropic/claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } },
      service_charges: {
        "anthropic" => {
          "web_search_request" => 10.0,
          "web_fetch_request" => 0.0,
          "code_execution_hour" => 0.05
        }
      }
    )
    provider_result = build_result(
      models: { "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } },
      service_charges: { "web_search_request" => 11.0, "code_execution_hour" => 0.06 }
    )

    with_registry(registry) do |path|
      described_class.new.call(provider: "anthropic", provider_result: provider_result, registry_path: path)

      service_charges = JSON.parse(File.read(path)).fetch("service_charges").fetch("anthropic")
      expect(service_charges).to eq(
        "web_search_request" => 11.0,
        "web_fetch_request" => 0.0,
        "code_execution_hour" => 0.06
      )
    end
  end

end
