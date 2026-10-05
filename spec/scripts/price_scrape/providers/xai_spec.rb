# frozen_string_literal: true

require "spec_helper"
require "price_scrape/providers/xai"

RSpec.describe LlmCostTracker::Pricing::Scrape::Providers::Xai do
  let(:pricing) { fixture("xai_pricing.md") }
  let(:pages) { pages_for(pricing) }
  let(:models) { described_class.new.call(html: pages).models }

  def fixture(name) = File.read("spec/fixtures/scrape/#{name}", encoding: "utf-8")

  def pages_for(pricing)
    described_class.followup_urls(described_class.source_url => pricing).to_h do |url|
      [url, fixture("xai_model_#{url[%r{models/(.+)\.md\z}, 1]}.md")]
    end.merge(described_class.source_url => pricing)
  end

  def scrape(page) = described_class.new.call(html: pages.merge(described_class.source_url => page))

  it "asks for the model page of every model in the text price table" do
    expect(described_class.followup_urls(described_class.source_url => pricing)).to eq(
      %w[grok-4.7 grok-4.6 grok-4.5 grok-4.3 grok-4.20-0309-reasoning grok-4.20-0309-non-reasoning grok-build-0.1
         grok-4.20-multi-agent-0309].map { |model| "https://docs.x.ai/developers/models/#{model}.md" }
    )
  end

  it "reads input, cached input and output, at long-context rates from 200K prompt tokens, image input as input" do
    expect(models.fetch("grok-4.7")).to include(
      "input" => 2.0, "cache_read_input" => 0.5, "output" => 6.0, "image_input" => 2.0,
      "_context_price_threshold_tokens" => 199_999, "above_context_input" => 4.0,
      "above_context_cache_read_input" => 1.0, "above_context_output" => 12.0, "above_context_image_input" => 4.0
    )
    expect(models.fetch("grok-4.5")).to include("cache_read_input" => 0.3, "above_context_cache_read_input" => 0.6)
  end

  it "prices priority at 2x every model's rates and the US regional endpoint at 1.1x for the models it lists" do
    expect(models.fetch("grok-4.7")).to include(
      "priority_input" => 4.0, "priority_cache_read_input" => 1.0, "priority_output" => 12.0,
      "above_context_priority_output" => 24.0, "data_residency_input" => 2.2, "data_residency_output" => 6.6,
      "above_context_data_residency_cache_read_input" => 1.1, "priority_data_residency_input" => 4.4,
      "above_context_priority_data_residency_output" => 26.4
    )
    expect(models.fetch("grok-4.3")).to include("priority_input" => 2.5, "priority_output" => 5.0)
    expect(models.fetch("grok-4.3").keys.grep(/data_residency/)).to be_empty
  end

  it "applies the batch discount to the models it lists, and gives each alias its model's fields" do
    batch = { "batch_input" => 1.0, "batch_cache_read_input" => 0.16, "batch_output" => 2.0,
              "above_context_batch_input" => 2.0, "above_context_batch_output" => 4.0 }

    expect(models.fetch("grok-4.3")).to include(batch)
    expect(models.fetch("grok-4.7").keys.grep(/batch/)).to be_empty
    expect(models.values_at("grok-4.3-latest", "grok-4.20", "grok-4.20-non-reasoning-gv2",
                            "grok-4.20-multi-agent-beta-0309")).to all(include(batch))
    expect(models.fetch("grok-code-fast-1")).to eq(models.fetch("grok-build-0.1"))
    expect(models.fetch("grok-build-latest")).to eq(models.fetch("grok-4.5"))
    expect(models.size).to eq(43)
  end

  it "prices an xAI call from exactly 200K prompt tokens at the long-context rates, as xAI bills it" do
    LlmCostTracker.configure { |c| c.pricing.overrides = { "xai/grok-4.7" => models.fetch("grok-4.7") } }
    cost = lambda do |input, mode = nil|
      LlmCostTracker::Pricing.cost_for(
        provider: "xai", model: "grok-4.7", pricing_mode: mode,
        tokens: LlmCostTracker::Usage::TokenUsage.build(input_tokens: input, output_tokens: 1000)
      ).total
    end

    expect([cost.call(1000), cost.call(199_999), cost.call(200_000), cost.call(1000, "priority")])
      .to eq(%w[0.008 0.405998 0.812 0.016].map { |total| BigDecimal(total) })
  end

  it "prices image prompt tokens at the input rate, and priority on the US endpoint at 2.2x" do
    LlmCostTracker.configure { |c| c.pricing.overrides = { "xai/grok-4.7" => models.fetch("grok-4.7") } }
    tokens = LlmCostTracker::Usage::TokenUsage.build(input_tokens: 200, image_input_tokens: 800, output_tokens: 100)
    cost = lambda do |mode|
      LlmCostTracker::Pricing.cost_for(provider: "xai", model: "grok-4.7", pricing_mode: mode, tokens: tokens).total
    end

    expect([cost.call(nil), cost.call("priority_data_residency")])
      .to eq(%w[0.0026 0.00572].map { |total| BigDecimal(total) })
  end

  it "takes a model priced without long-context rows at one rate" do
    page = pricing.sub("| grok-4.6 (< 200k prompt tokens) | 500k |", "| grok-4.6 | 500k |")
                  .sub(/^\| grok-4\.6 \(≥ 200k prompt tokens\).*\n/, "")

    expect(scrape(page).models.fetch("grok-4.6").keys.grep(/context/)).to be_empty
  end

  it "raises when the text price table, a price row, a tier's terms or an alias cannot be read" do
    error = described_class::Error
    expect { scrape(pricing.sub("### Text API Pricing", "### Token Pricing")) }
      .to raise_error(error, /text price table not found/)
    expect { scrape(pricing.sub("| Input / 1M tokens | Cached input", "| Cached input / 1M tokens | Input")) }
      .to raise_error(error, /text price table not found/)
    expect { scrape(pricing.sub("| $2.00 | $0.50 | $6.00 |", "| $2.00 | — | $6.00 |")) }
      .to raise_error(error, /price row not understood: \| grok-4\.7/)
    expect { scrape(pricing.sub(/^\| grok-4\.6 \(< 200k prompt tokens\).*\n/, "")) }
      .to raise_error(error, /long-context rows for grok-4\.6 not understood/)
    expect { scrape(pricing.sub("billed at a **2x** premium", "billed at a premium")) }
      .to raise_error(error, /xai priority rate not found/)
    expect { scrape(pricing.sub("Currently `grok-4.7` and `grok-4.6` only", "None")) }
      .to raise_error(error, /US regional models not found/)
    expect { scrape(pricing.sub("**20% off standard rates**", "**Discounted**")) }
      .to raise_error(error, /batch discounts not found/)
    expect { scrape(pricing.sub("- grok-4.3\n", "- grok-4.3\n- grok-4.8\n")) }
      .to raise_error(error, /batch discount for grok-4\.8 outside its price table/)
    expect { scrape(pricing.sub("- grok-4.3\n", "- grok-4.3\n- grok-4.7\n")) }.not_to raise_error

    twice = pages.merge(format(described_class::MODEL_PAGE, "grok-4.7") => fixture("xai_model_grok-4.3.md"))
    expect { described_class.new.call(html: twice) }.to raise_error(error, /lists grok-4\.3-latest twice/)
  end
end
