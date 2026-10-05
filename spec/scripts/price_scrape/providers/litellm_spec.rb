# frozen_string_literal: true

require "spec_helper"
require "json"
require "price_scrape/providers/mistral"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Litellm do
  let(:body) { fixture("litellm_prices.json") }
  let(:mistral_class) { LlmCostTracker::Pricing::Scrape::Providers::Mistral }
  let(:mistral_pages) do
    { described_class::SOURCE_URL => body, mistral_class::PRICING_SOURCE_URL => fixture("mistral_pricing.html") }
      .merge(mistral_class::TIER_SOURCES.to_h { |tier, (url, _)| [url, fixture("mistral_#{tier}.md")] })
  end
  let(:mistral) { mistral_class.new.call(html: mistral_pages).models }

  def fixture(name) = File.read("spec/fixtures/scrape/#{name}", encoding: "utf-8")

  it "prices only the Mistral models its pricing page lists, at the page's rates, under the names the API accepts" do
    catalogue = JSON.parse(body)
    catalogue["mistral/mistral-large-latest"]["input_cost_per_token"] = 0.000009
    models = mistral_class.new.call(html: mistral_pages.merge(described_class::SOURCE_URL => JSON.generate(catalogue)))
                          .models

    expect(models.transform_values { |fields| fields.slice("input", "cache_read_input", "output") }).to include(
      "mistral-large-latest" => { "input" => 0.5, "cache_read_input" => 0.05, "output" => 1.5 },
      "mistral-medium-latest" => { "input" => 1.5, "cache_read_input" => 0.15, "output" => 7.5 },
      "mistral-medium-3-5" => { "input" => 1.5, "cache_read_input" => 0.15, "output" => 7.5 },
      "codestral-latest" => { "input" => 0.3, "cache_read_input" => 0.03, "output" => 0.9 }
    )
    expect(models.keys).not_to include("mistral-small", "mistral-tiny", "pixtral-large-latest", "open-mistral-nemo",
                                       "codestral-mamba-latest", "devstral-small-latest", "voxtral-small-latest")
  end

  it "matches Mistral API names LiteLLM links to the pricing page to the one card named like them" do
    ministral8b = { "input" => 0.15, "cache_read_input" => 0.015, "output" => 0.15 }

    expect(mistral.values_at("ministral-8b-2512", "ministral-8b-latest")).to all(include(ministral8b))
    expect(mistral.keys).not_to include("ministral-3-8b-2512", "ministral-3-14b-2512")
  end

  it "prices Mistral batch at 50%, Priority Tier at 1.75x, the regional endpoints at 1.1x, and both together" do
    expect(mistral.fetch("mistral-medium-latest")).to eq(
      "input" => 1.5, "cache_read_input" => 0.15, "output" => 7.5,
      "batch_input" => 0.75, "batch_cache_read_input" => 0.075, "batch_output" => 3.75,
      "priority_input" => 2.625, "priority_cache_read_input" => 0.2625, "priority_output" => 13.125,
      "data_residency_input" => 1.65, "data_residency_cache_read_input" => 0.165, "data_residency_output" => 8.25,
      "priority_data_residency_input" => 2.8875, "priority_data_residency_cache_read_input" => 0.28875,
      "priority_data_residency_output" => 14.4375
    )

    priority_url = mistral_class::TIER_SOURCES.fetch("priority").first
    expect { mistral_class.new.call(html: mistral_pages.merge(priority_url => "# Priority Tier")) }
      .to raise_error(described_class::Error, /mistral priority rate not found/)
  end

  it "prices Mistral OCR per 1,000 pages from the Input column, under the card's API names and its -latest alias" do
    one_card = mistral_pages.merge(mistral_class::PRICING_SOURCE_URL => fixture("mistral_pricing.html")
                                     .sub(%r{<tr><td><a href="/models/ocr-4-0">.*?</tr>}, ""))
    models = mistral_class.new.call(html: one_card).models

    expect(models.slice("mistral-ocr-4-1", "mistral-ocr-4", "mistral-ocr-latest").values)
      .to eq([{ "ocr_page" => 4.0 }] * 3)
    expect(models.keys).not_to include("mistral-ocr-2512", "mistral-ocr-4-0", "voxtral-mini-latest")
    expect(mistral.keys).to include("mistral-ocr-4-1")
    expect(mistral.keys).not_to include("mistral-ocr-latest")
  end

  it "keeps only priced token and OCR models of its own provider" do
    expect(mistral.keys).not_to include("labs-leanstral-1-5", "mistral-embed", "mistral-moderation-2603",
                                        "deepseek-flash", "gpt-4o")
  end

  describe ".convert" do
    let(:conversion) { described_class.convert(JSON.parse(body)) }
    let(:models) { conversion.models }

    it "converts token rates per 1M tokens with their tier and long-context prefixes" do
      expect(models.fetch("openai/gpt-6-astra")).to include(
        "input" => 10.0, "cache_read_input" => 1.0, "cache_write_input" => 12.5, "output" => 50.0,
        "batch_input" => 5.0, "flex_output" => 25.0, "priority_input" => 20.0, "fast_input" => 20.0,
        "ultrafast_input" => 60.0, "ultrafast_cache_write_input" => 75.0, "ultrafast_output" => 300.0,
        "_context_price_threshold_tokens" => 272_000, "above_context_input" => 20.0,
        "above_context_ultrafast_output" => 450.0, "above_context_fast_cache_write_input" => 50.0,
        "web_search_request" => 10.0
      )
      expect(models.fetch("openai/gpt-6-astra").keys.grep(/data_residency/)).to be_empty
      expect(models.fetch("xai/grok-4.7")).to include("_context_price_threshold_tokens" => 199_999,
                                                       "above_context_input" => 4.0, "image_input" => 2.0)
    end

    it "maps cache writes, modality tokens and non-token units to the registry's dimensions" do
      expect(models.fetch("anthropic/claude-opus-4-8")).to include(
        "cache_write_input" => 6.25, "cache_write_extended_input" => 10.0, "batch_cache_write_input" => 3.125
      )
      expect(models.fetch("openai/gpt-realtime-2.1")).to include(
        "audio_input" => 32.0, "audio_cache_read_input" => 0.4, "image_cache_read_input" => 0.5, "audio_output" => 64.0
      )
      expect(models.fetch("gemini/gemini-3.8-flash")).to include("grounding_request" => 14.0,
                                                                  "maps_grounding_request" => 14.0)
      expect(models.fetch("deepseek/deepseek-flash")).to include("cache_read_input" => 0.006)
      expect(models.fetch("openai/whisper-1")).to eq("transcription_minute" => 0.006)
      expect(models.fetch("openai/tts-1")).to eq("text_to_speech_character" => 15.0)
      expect(models.fetch("openai/gpt-4o-transcribe")).not_to include("transcription_minute")
    end

    it "skips fine-tunes and modes the registry does not price" do
      expect(models.keys).not_to include("openai/ft:gpt-4o-mini-2024-07-18", "mistral/mistral-ocr-latest",
                                         "xai/grok-imagine-image")
    end

    it "lists price fields it does not know and prices it cannot represent" do
      expect(conversion.unknown).to include(
        "cache_creation_input_audio_token_cost" => ["openai/gpt-realtime-2.1"],
        "citation_cost_per_token" => ["perplexity/sonar-deep-research"],
        "output_cost_per_second" => ["openai/whisper-1"]
      )
      expect(conversion.unrepresentable).to include(
        "several long-context thresholds" => ["openrouter/qwen/qwen3-max"],
        "reasoning tokens priced apart from output" => ["perplexity/sonar-deep-research"]
      )
      expect(models.fetch("openrouter/qwen/qwen3-max").keys.grep(/above_context/)).to be_empty
    end

    it "converts off-peak prices to off_peak_ rates and their windows, ending a window at 24:00" do
      expect(models.fetch("deepseek/deepseek-flash")).to include(
        "input" => 0.3, "off_peak_input" => 0.15, "off_peak_cache_read_input" => 0.003, "off_peak_output" => 0.6,
        "_off_peak_windows" => [
          { "weekdays" => [1, 2, 3, 4, 5], "hours_utc" => ["00:00-01:00", "04:00-06:00", "10:00-24:00"] },
          { "weekdays" => [6, 7], "hours_utc" => ["00:00-24:00"] }
        ]
      )

      entry = JSON.parse(body).fetch("deepseek/deepseek-flash")
      named = entry.merge("off_peak_pricing" => entry["off_peak_pricing"].merge("windows" => [{ "weekdays" => ["sat"] }]))
      odd = described_class.convert("deepseek/deepseek-odd" => named)
      expect(odd.unrepresentable).to eq("time-of-day prices outside weekday windows (off_peak_pricing)" => ["deepseek/deepseek-odd"])
      expect(odd.models.fetch("deepseek/deepseek-odd").keys.grep(/off_peak/)).to be_empty
    end

    it "converts two contiguous price tiers into long-context rates and reports any other tiering" do
      tier = lambda do |range, rate|
        { "range" => range, "input_cost_per_token" => rate, "output_cost_per_token" => rate }
      end
      entry = { "litellm_provider" => "openrouter", "mode" => "chat",
                "tiered_pricing" => [tier.call([0, 256_000], 1e-07), tier.call([256_000, 1_000_000], 2e-07)] }
      four = entry.merge("tiered_pricing" => entry["tiered_pricing"] * 2)
      tiers = described_class.convert("openrouter/a/two" => entry, "openrouter/a/four" => four)

      expect(tiers.models.fetch("openrouter/a/two")).to eq(
        "input" => 0.1, "output" => 0.1, "above_context_input" => 0.2, "above_context_output" => 0.2,
        "_context_price_threshold_tokens" => 256_000
      )
      expect(tiers.unrepresentable)
        .to eq("price tiers other than two contiguous ones (tiered_pricing)" => ["openrouter/a/four"])
    end

    it "reads the regional uplift LiteLLM records without turning it into rates" do
      entries = conversion.entries

      expect(described_class.uplift(entries.fetch("openai/gpt-6-astra"))).to eq(1.1)
      expect(described_class.uplift(entries.fetch("anthropic/claude-opus-4-8"))).to eq(1.1)
      expect(described_class.uplift(entries.fetch("openai/gpt-4o"))).to be_nil
    end
  end

  it "raises when an anchor model disappears or the list is not JSON" do
    catalogue = JSON.parse(body).reject { |key, _| key == "mistral/mistral-large-latest" }

    expect { mistral_class.new.call(html: mistral_pages.merge(described_class::SOURCE_URL => JSON.generate(catalogue))) }
      .to raise_error(described_class::Error, /anchor models missing/)
    expect { mistral_class.new.call(html: mistral_pages.merge(described_class::SOURCE_URL => "[]")) }
      .to raise_error(described_class::Error, /not a JSON object/)
    expect { mistral_class.new.call(html: mistral_pages.merge(described_class::SOURCE_URL => "<html>")) }
      .to raise_error(described_class::Error, /invalid JSON/)
    expect { mistral_class.new.call(html: mistral_pages.merge(mistral_class::PRICING_SOURCE_URL => "<html></html>")) }
      .to raise_error(described_class::Error)
  end
end
