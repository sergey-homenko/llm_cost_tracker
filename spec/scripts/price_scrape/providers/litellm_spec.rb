# frozen_string_literal: true

require "spec_helper"
require "json"
require "price_scrape/providers/mistral"
require "price_scrape/providers/xai"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Litellm do
  let(:body) { fixture("litellm_prices.json") }
  let(:xai_class) { LlmCostTracker::Pricing::Scrape::Providers::Xai }
  let(:xai_pages) do
    { described_class::SOURCE_URL => body, xai_class::PRICING_SOURCE_URL => fixture("xai_pricing.md") }
      .merge(xai_class::BATCH_MODEL_URLS.to_h { |model, url| [url, fixture("xai_model_#{model}.md")] })
  end
  let(:xai) { xai_class.new.call(html: xai_pages).models }
  let(:mistral_class) { LlmCostTracker::Pricing::Scrape::Providers::Mistral }
  let(:mistral_pages) do
    { described_class::SOURCE_URL => body, mistral_class::PRICING_SOURCE_URL => fixture("mistral_pricing.html") }
      .merge(mistral_class::TIER_SOURCES.to_h { |tier, (url, _)| [url, fixture("mistral_#{tier}.md")] })
  end
  let(:mistral) { mistral_class.new.call(html: mistral_pages).models }

  def fixture(name) = File.read("spec/fixtures/scrape/#{name}", encoding: "utf-8")

  it "reads xAI token, cached, long-context and batch rates per 1M tokens" do
    expect(xai.fetch("grok-4.7")).to include(
      "input" => 2.0, "cache_read_input" => 0.5, "output" => 6.0, "image_input" => 2.0,
      "above_context_input" => 4.0, "above_context_cache_read_input" => 1.0, "above_context_output" => 12.0,
      "above_context_image_input" => 4.0
    )
    expect(xai.fetch("grok-4.7").keys.grep(/batch/)).to be_empty
    expect(xai.fetch("grok-4.3")).to include(
      "input" => 1.25, "cache_read_input" => 0.2, "output" => 2.5,
      "batch_input" => 1.0, "batch_cache_read_input" => 0.16, "batch_output" => 2.0, "above_context_batch_input" => 2.0
    )
  end

  it "takes xAI's long-context threshold only from the rates it keeps" do
    catalogue = JSON.parse(body)
    catalogue["xai/grok-4.7"]["input_cost_per_image_token_above_128k_tokens"] = 3e-06
    catalogue["xai/grok-4.6"] = catalogue["xai/grok-4.6"].reject { |name, _| name.include?("_above_") }
                                                         .merge("input_cost_per_image_token_above_128k_tokens" => 3e-06)
    models = xai_class.new.call(html: xai_pages.merge(described_class::SOURCE_URL => JSON.generate(catalogue))).models

    expect(models.fetch("grok-4.7")).to include("_context_price_threshold_tokens" => 199_999,
                                                "above_context_input" => 4.0)
    expect(models.fetch("grok-4.6").keys.grep(/context/)).to be_empty
  end

  it "gives the aliases xAI's model pages list for a batch model that model's batch rates" do
    batch = { "batch_input" => 1.0, "batch_cache_read_input" => 0.16, "batch_output" => 2.0,
              "above_context_batch_input" => 2.0, "above_context_batch_cache_read_input" => 0.32,
              "above_context_batch_output" => 4.0 }

    expect(xai.values_at("grok-4.20-beta", "grok-4.20-reasoning-gv2", "grok-4.20-multi-agent-beta-0309"))
      .to all(include(batch))
  end

  it "prices xAI priority at 2x every model's rates and the US regional endpoint at 1.1x, both there together" do
    expect(xai.fetch("grok-4.7")).to include(
      "priority_input" => 4.0, "priority_cache_read_input" => 1.0, "priority_output" => 12.0,
      "above_context_priority_input" => 8.0, "above_context_priority_output" => 24.0,
      "data_residency_input" => 2.2, "data_residency_cache_read_input" => 0.55, "data_residency_output" => 6.6,
      "above_context_data_residency_input" => 4.4, "above_context_data_residency_cache_read_input" => 1.1,
      "above_context_data_residency_output" => 13.2,
      "priority_data_residency_input" => 4.4, "priority_data_residency_cache_read_input" => 1.1,
      "priority_data_residency_output" => 13.2, "above_context_priority_data_residency_input" => 8.8,
      "above_context_priority_data_residency_cache_read_input" => 2.2,
      "above_context_priority_data_residency_output" => 26.4
    )
    expect(xai.fetch("grok-4.3")).to include("priority_input" => 2.5, "priority_output" => 5.0)
    expect(xai.fetch("grok-4.3").keys.grep(/data_residency/)).to be_empty
  end

  it "prices an xAI call from exactly 200K prompt tokens at the long-context rates, as xAI bills it" do
    LlmCostTracker.configure { |c| c.pricing.overrides = { "xai/grok-4.7" => xai.fetch("grok-4.7") } }
    cost = lambda do |input, mode = nil|
      LlmCostTracker::Pricing.cost_for(
        provider: "xai", model: "grok-4.7", pricing_mode: mode,
        tokens: LlmCostTracker::Usage::TokenUsage.build(input_tokens: input, output_tokens: 1000)
      ).total
    end

    expect([cost.call(1000), cost.call(199_999), cost.call(200_000), cost.call(1000, "priority")])
      .to eq(%w[0.008 0.405998 0.812 0.016].map { |total| BigDecimal(total) })
  end

  it "prices xAI image prompt tokens at the input rate, and priority on the US endpoint at 2.2x" do
    LlmCostTracker.configure { |c| c.pricing.overrides = { "xai/grok-4.7" => xai.fetch("grok-4.7") } }
    tokens = LlmCostTracker::Usage::TokenUsage.build(input_tokens: 200, image_input_tokens: 800, output_tokens: 100)
    cost = lambda do |mode|
      LlmCostTracker::Pricing.cost_for(provider: "xai", model: "grok-4.7", pricing_mode: mode, tokens: tokens).total
    end

    expect([cost.call(nil), cost.call("priority_data_residency")])
      .to eq(%w[0.0026 0.00572].map { |total| BigDecimal(total) })
  end

  it "raises when xAI's docs no longer state a tier's terms or list a batch model it has no page for" do
    pricing = xai_pages.fetch(xai_class::PRICING_SOURCE_URL)
    scrape = ->(page) { xai_class.new.call(html: xai_pages.merge(xai_class::PRICING_SOURCE_URL => page)) }

    expect { scrape.call(pricing.sub("- grok-4.3\n", "- grok-4.3\n- grok-4.7\n")) }
      .to raise_error(described_class::Error, /batch discount for grok-4.7; add its model page/)
    expect { scrape.call(pricing.sub("billed at a **2x** premium", "billed at a premium")) }
      .to raise_error(described_class::Error, /xai priority rate not found/)
    expect { scrape.call(pricing.sub("Currently `grok-4.7` and `grok-4.6` only", "None")) }
      .to raise_error(described_class::Error, /US regional models not found/)
  end

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

  it "keeps only priced token models of its own provider" do
    expect(xai.keys).not_to include("grok-imagine-image", "grok-voice-transcribe-1.0")
    expect(mistral.keys).not_to include("labs-leanstral-1-5", "mistral-embed", "mistral-ocr-latest")
    expect(xai.keys + mistral.keys).not_to include("deepseek-flash", "gpt-4o")
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
    catalogue = JSON.parse(body).reject { |key, _| key == "xai/grok-4.7" }

    expect { xai_class.new.call(html: xai_pages.merge(described_class::SOURCE_URL => JSON.generate(catalogue))) }
      .to raise_error(described_class::Error, /anchor models missing/)
    expect { mistral_class.new.call(html: mistral_pages.merge(described_class::SOURCE_URL => "[]")) }
      .to raise_error(described_class::Error, /not a JSON object/)
    expect { mistral_class.new.call(html: mistral_pages.merge(described_class::SOURCE_URL => "<html>")) }
      .to raise_error(described_class::Error, /invalid JSON/)
    expect { mistral_class.new.call(html: mistral_pages.merge(mistral_class::PRICING_SOURCE_URL => "<html></html>")) }
      .to raise_error(described_class::Error)
  end
end
