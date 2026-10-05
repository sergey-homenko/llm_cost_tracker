# frozen_string_literal: true

require "spec_helper"
require "json"
require "price_scrape/providers/mistral"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Litellm do
  let(:body) { fixture("litellm_prices.json") }
  let(:mistral_class) { LlmCostTracker::Pricing::Scrape::Providers::Mistral }
  let(:card_names) do
    {
      "mistral-medium-3-5-26-04" => %w[mistral-medium-3 mistral-medium-3-5 mistral-medium-latest],
      "codestral-embed-25-05" => %w[codestral-embed codestral-embed-2505],
      "voxtral-mini-transcribe-26-02" => %w[voxtral-mini-2602 voxtral-mini-latest],
      "zai-glm-5-2" => %w[zai-glm-5-2], "zai-glm-5-3" => %w[zai-glm-5 zai-glm-5-3 zai-glm-latest],
      "devstral-2-25-12" => %w[devstral-2512 devstral-latest devstral-medium-latest],
      "magistral-medium-1-2-25-09" => %w[magistral-medium-2509 magistral-medium-latest],
      "voxtral-mini-25-07" => %w[voxtral-mini-2507 voxtral-mini-latest],
      "mistral-nemo-12b-24-07" => %w[open-mistral-nemo open-mistral-nemo-2407], "mathstral-7b-0-1" => []
    }
  end
  let(:mistral_pages) do
    pages = { described_class::SOURCE_URL => body, described_class::MODELS_DEV_URL => fixture("models_dev.json"),
              mistral_class::PRICING_SOURCE_URL => fixture("mistral_pricing.html"),
              mistral_class::MODELS_SOURCE_URL => fixture("mistral_models.html") }
            .merge(mistral_class::TIER_SOURCES.to_h { |tier, (url, _)| [url, fixture("mistral_#{tier}.md")] })
    pages.merge(mistral_class.followup_urls(pages).to_h { |url| [url, card(card_names.fetch(url.split("/").last))] })
  end
  let(:mistral_result) { mistral_class.new.call(html: mistral_pages, scraped_at: "2026-10-05T06:00:00Z") }
  let(:mistral) { mistral_result.models }

  def fixture(name) = File.read("spec/fixtures/scrape/#{name}", encoding: "utf-8")

  def card(names) = %(<script>self.__next_f.push([1,"{\\"names\\":#{names.to_json.gsub('"', '\"')}}"])</script>)

  it "prices only the Mistral models its pricing page lists, at the page's rates, under the names the API accepts" do
    catalogue = JSON.parse(body)
    catalogue["mistral/mistral-large-latest"]["input_cost_per_token"] = 0.000009
    models = mistral_class.new.call(html: mistral_pages.merge(described_class::SOURCE_URL => JSON.generate(catalogue)),
                                    scraped_at: "2026-10-05T06:00:00Z").models

    expect(models.transform_values { |fields| fields.slice("input", "cache_read_input", "output") }).to include(
      "mistral-large-latest" => { "input" => 0.5, "cache_read_input" => 0.05, "output" => 1.5 },
      "mistral-medium-latest" => { "input" => 1.5, "cache_read_input" => 0.15, "output" => 7.5 },
      "mistral-medium-3-5" => { "input" => 1.5, "cache_read_input" => 0.15, "output" => 7.5 },
      "codestral-latest" => { "input" => 0.3, "cache_read_input" => 0.03, "output" => 0.9 }
    )
    expect(models.keys).not_to include("mistral-small", "mistral-tiny", "open-mistral-nemo", "codestral-mamba-latest",
                                       "devstral-small-latest", "voxtral-small-latest")
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
    models = mistral_class.new.call(html: one_card, scraped_at: "2026-10-05T06:00:00Z").models

    expect(models.slice("mistral-ocr-4-1", "mistral-ocr-4", "mistral-ocr-latest").values)
      .to eq([{ "ocr_page" => 4.0 }] * 3)
    expect(models.keys).not_to include("mistral-ocr-2512", "mistral-ocr-4-0", "voxtral-mini-latest")
    expect(mistral.keys).to include("mistral-ocr-4-1")
    expect(mistral.keys).not_to include("mistral-ocr-latest")
  end

  it "keeps only priced token, embedding and OCR models of its own provider" do
    expect(mistral.keys).not_to include("labs-leanstral-1-5", "mistral-moderation-2603", "voxtral-mini-2602",
                                        "deepseek-flash", "gpt-4o")
  end

  it "adds the Mistral models only LiteLLM prices when models.dev lists the same price, at Mistral's tier rates" do
    expect(mistral.fetch("pixtral-large-latest")).to include(
      "_source" => "litellm", "input" => 2.0, "cache_read_input" => 0.2, "output" => 6.0, "batch_input" => 1.0,
      "priority_output" => 10.5, "data_residency_input" => 2.2, "priority_data_residency_input" => 3.85
    )
    expect(mistral.fetch("mistral-embed")).to eq(
      "_source" => "litellm", "input" => 0.1, "batch_input" => 0.05, "priority_input" => 0.175,
      "data_residency_input" => 0.11, "priority_data_residency_input" => 0.1925
    )
    expect(mistral.keys).not_to include("open-mistral-nemo", "voxtral-small-latest")
    expect(mistral.fetch("mistral-large-latest")).not_to have_key("_source")
  end

  it "deprecates the ids Mistral's retired models table and the retired models' cards name, and writes none of them" do
    expect(mistral_result.deprecated_models).to contain_exactly(
      "devstral-2512", "devstral-latest", "devstral-medium-latest", "magistral-medium-2509", "magistral-medium-latest",
      "voxtral-mini-2507", "open-mistral-nemo", "open-mistral-nemo-2407"
    )
    expect(mistral.keys).not_to include("devstral-latest", "devstral-medium-latest")
    expect(mistral.keys).to include("zai-glm-5-2")
  end

  it "writes no LiteLLM row for an id both a retired and a current card name, and reports it" do
    card_names.merge!("mistral-nemo-12b-24-07" => %w[open-mistral-nemo mistral-embed],
                      "mathstral-7b-0-1" => %w[mistral-embed])

    expect(mistral.keys).not_to include("mistral-embed")
    expect(mistral_result.deprecated_models).not_to include("mistral-embed", "voxtral-mini-latest")
    expect(mistral_result.notes)
      .to eq(["- `mistral/mistral-embed`: named on both a retired and a current Mistral model card; not written"])
  end

  it "raises when Mistral's retired models table or a model card's API names go missing" do
    card_url = "#{mistral_class::MODELS_SOURCE_URL}/devstral-2-25-12"

    expect { mistral_class.new.call(html: mistral_pages.merge(mistral_class::MODELS_SOURCE_URL => "<html></html>")) }
      .to raise_error(described_class::Error, /retired models table not found/)
    expect { mistral_class.new.call(html: mistral_pages.merge(card_url => "<html></html>")) }
      .to raise_error(described_class::Error, %r{card #{card_url} lists no API names})
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
      expect(models.keys).not_to include("openai/ft:gpt-4o-mini-2024-07-18", "xai/grok-imagine-image",
                                         "mistral/mistral-moderation-2603")
    end

    it "converts OCR pages and rerank search units per 1,000, and reports OCR annotation and batch pages" do
      expect(models.fetch("mistral/mistral-ocr-latest")).to eq("ocr_page" => 4.0)
      expect(models.fetch("cohere/rerank-v3.5")).to eq("rerank_search_unit" => 2.0)
      expect(conversion.unrepresentable.fetch("OCR annotation and batch OCR pages"))
        .to include("mistral/mistral-ocr-latest", "mistral/mistral-ocr-2512")
      expect(conversion.unknown.keys).not_to include("annotation_cost_per_page", "ocr_cost_per_page_batches")
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

  describe ".gate" do
    def entry(input, output, **extra)
      { "litellm_provider" => "mistral", "mode" => "chat", "input_cost_per_token" => input / 1e6,
        "output_cost_per_token" => output / 1e6 }.merge(extra.transform_keys(&:to_s))
    end

    def cost(input, output) = { "cost" => { "input" => input, "output" => output } }

    let(:catalogue) do
      {
        "mistral/official" => entry(1.0, 2.0), "mistral/official-2026-01-01" => entry(5.0, 6.0),
        "mistral/confirmed" => entry(1.0, 2.0), "mistral/confirmed-2026-01-01" => entry(1.0, 2.0),
        "mistral/held" => entry(1.0, 2.0), "mistral/unlisted" => entry(1.0, 2.0),
        "mistral/unlisted-20260101" => entry(3.0, 4.0), "mistral/embedder" => entry(0.1, 0.0, mode: "embedding"),
        "mistral/retired" => entry(1.0, 2.0, deprecation_date: "2026-10-04"),
        "mistral/retiring" => entry(1.0, 2.0, deprecation_date: "2026-10-05"),
        "mistral/no-output" => entry(1.0, 0.0),
        "mistral/transcriber" => entry(0.0, 0.0, mode: "audio_transcription", input_cost_per_second: 0.0001),
        "groq/elsewhere" => entry(1.0, 2.0, litellm_provider: "groq")
      }
    end
    let(:models_dev) do
      { "mistral" => { "models" => {
        "official" => cost(9, 9), "confirmed" => cost(1.005, 2), "held" => cost(1, 2.5), "embedder" => cost(0.1, 0),
        "retired" => cost(1, 2), "retiring" => cost(1, 2), "no-output" => cost(1, 0), "transcriber" => cost(0, 0)
      } } }
    end
    let(:gate) do
      described_class.gate("mistral", described_class.convert(catalogue), models_dev,
                           { "official" => { "input" => 5.0, "output" => 6.0 } }, "2026-10-05")
    end

    it "confirms LiteLLM-only chat and embedding rows models.dev prices within 1%, while not retired" do
      expect(gate.confirmed).to eq(
        "confirmed" => { "input" => 1.0, "output" => 2.0 }, "retiring" => { "input" => 1.0, "output" => 2.0 },
        "embedder" => { "input" => 0.1 }
      )
    end

    it "holds back rows models.dev prices otherwise and lists rows it does not list as unconfirmed" do
      expect(gate.held).to eq("held" => [[1.0, 2.0], [1.0, 2.5]])
      expect(gate.unconfirmed).to contain_exactly("unlisted", "unlisted-20260101")
    end

    it "leaves out officially priced models, dated twins at the same prices, other providers and other modes" do
      seen = gate.confirmed.keys + gate.held.keys + gate.unconfirmed

      expect(seen).not_to include("official", "official-2026-01-01", "confirmed-2026-01-01", "retired", "no-output",
                                  "transcriber", "elsewhere")
    end

    it "marks the confirmed rows a scraper writes as LiteLLM's" do
      pages = { described_class::SOURCE_URL => JSON.generate(catalogue),
                described_class::MODELS_DEV_URL => JSON.generate(models_dev) }

      expect(described_class.confirmed_rows("mistral", pages, {}, "2026-10-05T06:00:00Z").fetch("confirmed"))
        .to eq("input" => 1.0, "output" => 2.0, "_source" => "litellm")
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
