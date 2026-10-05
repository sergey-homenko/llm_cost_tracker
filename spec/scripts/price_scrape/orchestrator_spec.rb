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

  it "writes the canonical source_urls into metadata when models change" do
    registry = build_registry(
      models: { "anthropic/claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } },
      metadata: { "source_urls" => ["https://old.example.com/pricing"] }
    )
    provider_result = build_result(models: { "claude-opus-4-7" => { "input" => 6.0, "output" => 25.0 } })

    with_registry(registry) do |path|
      described_class.new(today: Date.new(2026, 4, 26)).call(
        provider: "anthropic",
        provider_result: provider_result,
        registry_path: path,
        source_urls: ["https://new.example.com/pricing", "https://new.example.com/cache"]
      )

      written = JSON.parse(File.read(path))
      expect(written.dig("metadata", "source_urls")).to eq(
        ["https://new.example.com/pricing", "https://new.example.com/cache"]
      )
    end
  end

  it "rewrites stale source_urls even when no model prices changed" do
    registry = build_registry(
      models: { "anthropic/claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } },
      metadata: { "source_urls" => ["https://dead.example.com/pricing"] }
    )
    provider_result = build_result(models: { "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } })

    with_registry(registry) do |path|
      result = described_class.new(today: Date.new(2026, 4, 26)).call(
        provider: "anthropic",
        provider_result: provider_result,
        registry_path: path,
        source_urls: ["https://live.example.com/pricing"]
      )

      expect(result.changed?).to be(false)
      expect(result.written).to be(true)
      written = JSON.parse(File.read(path))
      expect(written.dig("metadata", "source_urls")).to eq(["https://live.example.com/pricing"])
      expect(written.dig("metadata", "updated_at")).to eq("2026-04-26")
    end
  end

  it "leaves the registry untouched when source_urls already match and nothing changed" do
    registry = build_registry(
      models: { "anthropic/claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } },
      metadata: { "source_urls" => ["https://live.example.com/pricing"], "updated_at" => "2026-04-01" }
    )
    provider_result = build_result(models: { "claude-opus-4-7" => { "input" => 5.0, "output" => 25.0 } })

    with_registry(registry) do |path|
      result = described_class.new(today: Date.new(2026, 4, 26)).call(
        provider: "anthropic",
        provider_result: provider_result,
        registry_path: path,
        source_urls: ["https://live.example.com/pricing"]
      )

      expect(result.written).to be(false)
      expect(JSON.parse(File.read(path)).dig("metadata", "updated_at")).to eq("2026-04-01")
    end
  end

  it "does not delete another provider's namespaced model when an aggregator scrape's id matches (e.g. OpenRouter reporting `openai/gpt-4o` does not nuke the direct openai entry)" do
    registry = build_registry(models: {
                                "openai/gpt-4o" => { "input" => 2.5, "output" => 10.0 }
                              })
    provider_result = build_result(
      models: { "openai/gpt-4o" => { "input" => 2.5, "output" => 10.0 } }
    )

    with_registry(registry) do |path|
      result = described_class.new.call(
        provider: "openrouter", provider_result: provider_result, registry_path: path
      )

      expect(result.removed).to eq([])
      models = JSON.parse(File.read(path)).fetch("models")
      expect(models).to have_key("openai/gpt-4o")
      expect(models).to have_key("openrouter/openai/gpt-4o")
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
                                  "_note" => "kept"
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
        "_note" => "kept",
        "batch_input" => 2.5,
        "batch_output" => 12.5
      )
    end
  end

  it "treats a row's _source as scraped, so a LiteLLM row the official table takes over loses it" do
    litellm = { "input" => 0.1, "_source" => "litellm" }
    scrape = lambda do |fields, path|
      described_class.new.call(provider: "mistral", provider_result: build_result(models: { "mistral-embed" => fields }),
                               registry_path: path)
    end

    with_registry(build_registry(models: { "mistral/mistral-embed" => litellm })) do |path|
      expect(scrape.call(litellm, path).changed?).to be(false)
      expect(scrape.call({ "input" => 0.1 }, path).updated)
        .to eq("mistral/mistral-embed" => { "_source" => { "from" => "litellm", "to" => nil } })
      expect(JSON.parse(File.read(path)).dig("models", "mistral/mistral-embed")).to eq("input" => 0.1)
    end
  end

  it "updates long-context rates but refuses to drop a tier the scraper stopped returning" do
    base = { "input" => 4.0, "output" => 20.0 }
    long_context = { "_context_price_threshold_tokens" => 272_000, "above_context_input" => 8.0 }
    registry = build_registry(
      models: { "openai/gpt-5.6-sol" => base.merge(long_context, "above_context_input" => 10.0) }
    )
    scrape = lambda do |fields, path|
      described_class.new.call(
        provider: "openai", provider_result: build_result(models: { "gpt-5.6-sol" => fields }), registry_path: path
      )
    end

    with_registry(registry) do |path|
      scrape.call(base.merge(long_context), path)
      updated = File.read(path)
      expect(JSON.parse(updated).dig("models", "openai/gpt-5.6-sol")).to include(long_context)

      expect { scrape.call(base, path) }
        .to raise_error(described_class::Error, %r{refusing to drop long-context pricing for openai/gpt-5\.6-sol})
      expect(File.read(path)).to eq(updated)
    end
  end

  it "writes off-peak windows as scraped fields, so an unchanged scrape leaves the registry as it was" do
    windows = [{ "weekdays" => [6, 7], "hours_utc" => ["00:00-24:00"] }]
    fields = { "input" => 0.3, "output" => 1.2, "off_peak_input" => 0.15, "_off_peak_windows" => windows }
    scrape = lambda do |scraped, path|
      described_class.new.call(provider: "deepseek", provider_result: build_result(models: { "deepseek-flash" => scraped }),
                               registry_path: path)
    end

    with_registry(build_registry(models: {}, metadata: { "min_gem_version" => "0.15.0" })) do |path|
      expect(scrape.call(fields, path).added).to eq(["deepseek/deepseek-flash"])
      written = File.read(path)
      expect(JSON.parse(written).dig("models", "deepseek/deepseek-flash", "_off_peak_windows")).to eq(windows)

      expect(scrape.call(fields, path).changed?).to be(false)
      expect(File.read(path)).to eq(written)
      sunday = [{ "weekdays" => [7], "hours_utc" => ["00:00-24:00"] }]
      expect(scrape.call(fields.merge("_off_peak_windows" => sunday), path).updated)
        .to eq("deepseek/deepseek-flash" => { "_off_peak_windows" => { "from" => windows, "to" => sunday } })
    end
  end

  it "holds entries released gems would misprice until metadata.min_gem_version covers the gem that prices them" do
    windows = [{ "weekdays" => [6, 7], "hours_utc" => ["00:00-24:00"] }]
    models = { "deepseek-flash" => { "input" => 0.3, "off_peak_input" => 0.15, "_off_peak_windows" => windows },
               "deepseek-v4-pro" => { "input" => 1.32, "output" => 3.96 } }
    scrape = lambda do |min_gem_version|
      registry = build_registry(models: { "openai/gpt-4o" => { "input" => 2.5 } },
                                metadata: { "min_gem_version" => min_gem_version })
      with_registry(registry) do |path|
        results = [["deepseek", models], ["openai", { "gpt-4o-mini-tts" => { "input" => 0.6, "audio_output" => 12.0 } }],
                   ["mistral", { "mistral-ocr-latest" => { "ocr_page" => 4.0 } }]].map do |provider, scraped|
          described_class.new.call(provider: provider, provider_result: build_result(models: scraped), registry_path: path)
        end
        [results, JSON.parse(File.read(path)).fetch("models").keys]
      end
    end

    held, written = scrape.call("0.4.0")
    expect(held.map(&:added)).to eq([["deepseek/deepseek-v4-pro"], [], []])
    expect(held.flat_map(&:notes)).to eq(
      ["- `deepseek`: deepseek-flash held until metadata.min_gem_version is 0.15.0",
       "- `openai`: gpt-4o-mini-tts held until metadata.min_gem_version is 0.15.0",
       "- `mistral`: mistral-ocr-latest held until metadata.min_gem_version is 0.15.0"]
    )
    expect(written).not_to include("deepseek/deepseek-flash", "openai/gpt-4o-mini-tts", "mistral/mistral-ocr-latest")

    released, written = scrape.call("0.15.0")
    expect(released.flat_map(&:added)).to include("deepseek/deepseek-flash", "openai/gpt-4o-mini-tts",
                                                  "mistral/mistral-ocr-latest")
    expect(released.flat_map(&:notes)).to be_empty
    expect(written).to include("deepseek/deepseek-flash", "openai/gpt-4o-mini-tts", "mistral/mistral-ocr-latest")
  end

  describe "pruning" do
    let(:prices) { { "input" => 1.0, "output" => 2.0 } }
    let(:only_opus) { build_result(models: { "claude-opus-4-7" => prices }) }

    def scrape(path, provider_result, today: Date.new(2026, 10, 5))
      described_class.new(today: today).call(provider: "anthropic", provider_result: provider_result,
                                             registry_path: path)
    end

    it "dates the keys a provider stopped listing, clears reappearing ones and deletes those absent for 90 days" do
      keys = %w[claude-opus-4-7 claude-gone claude-back claude-old claude-older claude-sonnet-3-7]
      absent_since = { "anthropic/claude-back" => "2026-09-01", "anthropic/claude-old" => "2026-07-08",
                       "anthropic/claude-older" => "2026-07-07", "openai/gpt-gone" => "2026-01-01" }
      registry = build_registry(models: keys.to_h { |key| ["anthropic/#{key}", prices] }.merge("openai/gpt-gone" => prices),
                                metadata: { "absent_since" => absent_since })
      result = build_result(models: { "claude-opus-4-7" => prices, "claude-back" => prices },
                            deprecated_models: ["claude-sonnet-3-7"])

      with_registry(registry) do |path|
        plan = scrape(path, result)

        expect(plan.absent).to eq(
          "anthropic/claude-back" => { "from" => "2026-09-01", "to" => nil },
          "anthropic/claude-gone" => { "from" => nil, "to" => "2026-10-05" },
          "anthropic/claude-older" => { "from" => "2026-07-07", "to" => nil }
        )
        expect(plan.removed).to contain_exactly("anthropic/claude-sonnet-3-7", "anthropic/claude-older")
        written = JSON.parse(File.read(path))
        expect(written.dig("metadata", "absent_since")).to eq(
          "anthropic/claude-gone" => "2026-10-05", "anthropic/claude-old" => "2026-07-08",
          "openai/gpt-gone" => "2026-01-01"
        )
        expect(written["models"].keys).to contain_exactly(
          "anthropic/claude-opus-4-7", "anthropic/claude-gone", "anthropic/claude-back", "anthropic/claude-old",
          "openai/gpt-gone"
        )
      end
    end

    it "keeps the first absence date, writes nothing while the key stays absent, and drops it after 90 days" do
      registry = build_registry(models: { "anthropic/claude-opus-4-7" => prices, "anthropic/claude-gone" => prices })

      with_registry(registry) do |path|
        expect(scrape(path, only_opus).absent)
          .to eq("anthropic/claude-gone" => { "from" => nil, "to" => "2026-10-05" })
        written = File.read(path)
        expect(scrape(path, only_opus, today: Date.new(2027, 1, 2)).written).to be(false)
        expect(File.read(path)).to eq(written)
        expect(scrape(path, only_opus, today: Date.new(2027, 1, 3)).removed).to eq(["anthropic/claude-gone"])
        expect(JSON.parse(File.read(path))).to include("models" => { "anthropic/claude-opus-4-7" => prices })
        expect(JSON.parse(File.read(path))["metadata"]).not_to have_key("absent_since")
      end
    end

    it "counts entries held for a newer gem as listed and never dates hand-maintained rows" do
      windows = [{ "weekdays" => [6, 7], "hours_utc" => ["00:00-24:00"] }]
      models = { "deepseek/deepseek-flash" => prices, "openai/tts-1" => { "text_to_speech_character" => 15.0 } }

      with_registry(build_registry(models: models)) do |path|
        held = described_class.new.call(
          provider: "deepseek", registry_path: path,
          provider_result: build_result(models: { "deepseek-flash" => prices.merge("_off_peak_windows" => windows) })
        )
        listed = described_class.new.call(provider: "openai", provider_result: build_result(models: {}),
                                          registry_path: path)

        expect([held.absent, listed.absent]).to eq([{}, {}])
      end
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
        "priority_web_search_request" => { "from" => 12.0, "to" => nil },
        "file_search_call" => { "from" => nil, "to" => 2.5 }
      )

      service_charges = JSON.parse(File.read(path)).fetch("service_charges")
      expect(service_charges.fetch("anthropic")).to eq("web_search_request" => 10.0)
      expect(service_charges.fetch("openai")).to eq(
        "web_search_request" => 10.0,
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

  it "drops stale service charge keys when the scraper produces a different subset" do
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
      result = described_class.new.call(provider: "anthropic", provider_result: provider_result, registry_path: path)

      expect(result.service_charges_updated).to eq(
        "web_search_request" => { "from" => 10.0, "to" => 11.0 },
        "web_fetch_request" => { "from" => 0.0, "to" => nil },
        "code_execution_hour" => { "from" => 0.05, "to" => 0.06 }
      )

      service_charges = JSON.parse(File.read(path)).fetch("service_charges").fetch("anthropic")
      expect(service_charges).to eq(
        "web_search_request" => 11.0,
        "code_execution_hour" => 0.06
      )
    end
  end
end
