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
    # xAI docs: grok-4.7 $2 in / $0.50 cached / $6 out, $4 / $1 / $12 from 200K prompt tokens;
    # grok-4.3 $1.25 / $0.20 / $2.50 with a 20% batch discount. One input price per model, image tokens included.
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

  it "gives the aliases xAI's model pages list for a batch model that model's batch rates" do
    # docs.x.ai/developers/models/grok-4.20-0309-reasoning and grok-4.20-multi-agent-0309 list these aliases.
    batch = { "batch_input" => 1.0, "batch_cache_read_input" => 0.16, "batch_output" => 2.0,
              "above_context_batch_input" => 2.0, "above_context_batch_cache_read_input" => 0.32,
              "above_context_batch_output" => 4.0 }

    expect(xai.values_at("grok-4.20-beta", "grok-4.20-reasoning-gv2", "grok-4.20-multi-agent-beta-0309"))
      .to all(include(batch))
  end

  it "prices xAI priority at 2x every model's rates and the US regional endpoint at 1.1x, both there together" do
    # docs.x.ai/developers/pricing: grok-4.7 on us.api.x.ai is $2.20 / $0.55 / $6.60, $4.40 / $1.10 / $13.20 from 200K;
    # priority is 2x on every token type, so priority there is $4.40 / $1.10 / $13.20, $8.80 / $2.20 / $26.40 from 200K.
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
    # docs.x.ai: chat usage reports image_tokens within prompt_tokens, billed at the model's one input price.
    # grok-4.7: (200 + 800) x $2 + 100 x $6 per 1M = $0.0026; priority on us.api.x.ai (2x x 1.1x) = $0.00572.
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
    # docs.mistral.ai/inference/pricing: Large 3 $0.5 / $0.05 cached / $1.5, Medium 3.5 $1.5 / $0.15 / $7.5,
    # Codestral $0.3 / $0.03 / $0.9; Magistral, Devstral, Pixtral, Nemo and Voxtral Small are not listed.
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
    # docs.mistral.ai/models/ministral-3-8b-25-12 lists the API names ministral-8b-2512 and ministral-8b-latest.
    ministral8b = { "input" => 0.15, "cache_read_input" => 0.015, "output" => 0.15 }

    expect(mistral.values_at("ministral-8b-2512", "ministral-8b-latest")).to all(include(ministral8b))
    expect(mistral.keys).not_to include("ministral-3-8b-2512", "ministral-3-14b-2512")
  end

  it "prices Mistral batch at 50%, Priority Tier at 1.75x, the regional endpoints at 1.1x, and both together" do
    # docs.mistral.ai: batch processing, priority tier and regional inference billing. No combined rate is published,
    # so Priority Tier on a regional endpoint compounds the two multipliers (1.925x).
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
