# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "yaml"

RSpec.describe LlmCostTracker::Pricing::Calculation do
  it "prices a token line item at the exact per-million rate" do
    LlmCostTracker.configure do |c|
      c.pricing.overrides = { "demo-token" => { "input" => 2.5 } }
    end

    line_item = LlmCostTracker::Charges::LineItem.build(dimension_key: "input", quantity: 1_234_567)
    calculation = described_class.for(
      provider: "demo", model: "demo-token",
      tokens: LlmCostTracker::Usage::TokenUsage.build(input_tokens: 1_234_567, output_tokens: 0),
      line_items: [line_item], pricing_mode: nil
    )

    priced = calculation.priced_line_items.find(&:token?)
    expect(priced.cost).to eq(BigDecimal("3.0864175"))
    expect(priced.rate_quantity).to eq(BigDecimal(1_000_000))
    expect(priced.cost_status).to eq(LlmCostTracker::Charges::CostStatus::COMPLETE)
  end

  describe "off-peak windows" do
    let(:off_peak_entry) do
      { "input" => 0.3, "cache_read_input" => 0.006, "output" => 1.2, "off_peak_input" => 0.15,
        "off_peak_output" => 0.6, "batch_input" => 0.2, "batch_output" => 0.8, "batch_off_peak_input" => 0.1,
        "batch_off_peak_output" => 0.4,
        "_off_peak_windows" => [{ "weekdays" => [1, 2, 3, 4, 5], "hours_utc" => ["00:00-01:00", "10:00-24:00"] }] }
    end

    before { LlmCostTracker.configure { |c| c.pricing.overrides = { "deepseek/deepseek-flash" => off_peak_entry } } }

    def calculation(at, mode = nil)
      described_class.for(provider: "deepseek", model: "deepseek-flash", pricing_mode: mode, at: at,
                          tokens: { input_tokens: 1_000_000, cache_read_input_tokens: 1_000_000,
                                    output_tokens: 1_000_000 })
    end

    it "adds off_peak to the mode of a call made inside a window and prices it at the off_peak_ rates" do
      off_peak = calculation(Time.utc(2026, 9, 28, 0, 59, 59))
      peak = calculation(Time.utc(2026, 9, 28, 1))

      expect([off_peak.mode, off_peak.cost.total]).to eq(["off_peak", BigDecimal("0.753")])
      expect(off_peak.priced_line_items.map(&:price_key)).to eq(%w[off_peak_input off_peak_cache_read_input off_peak_output])
      expect([peak.mode, peak.cost.total]).to eq([nil, BigDecimal("1.506")])
    end

    it "composes off_peak with the call's own mode" do
      batch = calculation(Time.utc(2026, 9, 28, 12), "batch")

      expect([batch.mode, batch.cost.total]).to eq(["batch_off_peak", BigDecimal("0.502")])
    end

    it "ignores off_peak passed as a pricing mode, so only the windows apply it" do
      peak = calculation(Time.utc(2026, 9, 28, 1), "off_peak")
      batch = calculation(Time.utc(2026, 9, 28, 1), "batch_off_peak")

      expect([peak.mode, peak.cost.total, batch.mode]).to eq([nil, BigDecimal("1.506"), "batch"])
    end

    context "when the matched entry has no windows" do
      let(:off_peak_entry) { super().except("_off_peak_windows") }

      it "prices every call at the standard rates, off_peak requested or not" do
        expect([nil, "off_peak"].map { |mode| calculation(Time.utc(2026, 9, 28, 12), mode).then { [_1.mode, _1.cost.total] } })
          .to eq([[nil, BigDecimal("1.506")]] * 2)
      end
    end
  end

  describe "models priced only per unit" do
    before do
      LlmCostTracker.configure do |c|
        c.pricing.overrides = { "mistral/voxtral-mini-latest" => { "transcription_minute" => 0.003 } }
      end
    end

    def minutes(seconds) = LlmCostTracker::Charges::LineItem.build(dimension_key: "transcription_minute",
                                                                    quantity: BigDecimal(seconds) / 60)

    def calculation(model, tokens, line_items)
      described_class.for(provider: model.split("/").first, model: model.split("/").last, pricing_mode: nil,
                          tokens: tokens, line_items: line_items)
    end

    it "bills the minutes and keeps the tokens the response also reports unbilled" do
      priced = calculation("mistral/voxtral-mini-latest", { input_tokens: 4, output_tokens: 635 }, [minutes(203)])

      expect(priced).to have_attributes(cost_status: "complete")
      expect(priced.cost.total.round(8)).to eq(BigDecimal("0.01015"))
      expect(priced.priced_line_items.map(&:kind)).to eq(["transcription_minute"])
    end

    it "leaves tokens unknown when the call carries no unit the model is priced by" do
      expect(calculation("mistral/voxtral-mini-latest", { input_tokens: 4, output_tokens: 635 }, []).cost_status)
        .to eq("unknown")
    end
  end

  it "ignores a token-unit line item passed as a service line so token cost is not double-counted" do
    LlmCostTracker.configure { |c| c.pricing.overrides = { "dup-model" => { "input" => 2.0 } } }
    token_line = LlmCostTracker::Charges::LineItem.build(
      kind: "input", direction: "input", modality: "text", cache_state: "none",
      unit: "token", quantity: 1_000_000, dimension_key: "input"
    )
    calculation = described_class.for(
      provider: "custom", model: "dup-model",
      tokens: { input_tokens: 1_000_000 }, pricing_mode: nil, line_items: [token_line]
    )

    expect(calculation.cost.total).to eq(BigDecimal("2.0"))
    expect(calculation.priced_line_items.count(&:token?)).to eq(1)
  end

  it "lists derived batch cache rates in the snapshot and on their line items" do
    calculation = described_class.for(
      provider: "anthropic", model: "claude-sonnet-4-6", pricing_mode: "batch",
      tokens: { input_tokens: 1000, cache_write_input_tokens: 10_000, cache_read_input_tokens: 20_000,
                output_tokens: 500 }
    )

    rates = calculation.snapshot.fetch("rates").transform_values { |rate| rate.fetch("amount") }
    covered = calculation.priced_line_items.sum { |item| rates.fetch(item.price_key).to_d * item.quantity / 1_000_000 }

    expect(calculation.cost.total).to eq(BigDecimal("0.027"))
    expect(rates).to include("batch_cache_read_input" => "0.15", "batch_cache_write_input" => "1.875")
    expect(covered).to eq(BigDecimal("0.027"))
  end

  it "writes a service-sourced pricing snapshot when a service charge is priced without a model match" do
    line_item = LlmCostTracker::Charges::LineItem.build(dimension_key: "web_search_request", quantity: 2)
    calculation = described_class.for(
      provider: "anthropic", model: "model-without-any-price",
      tokens: { input_tokens: 0, output_tokens: 0 }, pricing_mode: nil, line_items: [line_item]
    )

    expect(calculation.cost.total).to eq(BigDecimal("0.02"))
    expect(calculation.snapshot).to include(
      "source" => "bundled",
      "matched_by" => "service_charges",
      "currency" => "USD"
    )
    expect(calculation.snapshot.fetch("rates")).to have_key("service_charges.anthropic.web_search_request")
  end

  it "leaves the cost nil when usage is unknown on a priced model, but still totals priced service lines" do
    unknown = LlmCostTracker::Usage::Source::UNKNOWN
    search = LlmCostTracker::Charges::LineItem.build(dimension_key: "web_search_request", quantity: 1)
    no_usage = described_class.for(provider: "openai", model: "gpt-4o", tokens: {}, pricing_mode: nil,
                                   usage_source: unknown)
    with_search = described_class.for(provider: "anthropic", model: "claude-sonnet-4-5", tokens: {},
                                      pricing_mode: nil, usage_source: unknown, line_items: [search])

    expect(no_usage.cost).to be_nil
    expect(with_search.cost.total).to eq(BigDecimal("0.01"))
    expect(with_search.cost_status).to eq(LlmCostTracker::Charges::CostStatus::UNKNOWN)
  end

  it "keeps service rates dropped from the total on currency mismatch out of the snapshot" do
    LlmCostTracker.configure { |c| c.pricing.overrides = { "snap-model" => { "input" => 2.0 } } }
    eur_line = LlmCostTracker::Charges::LineItem.build(
      dimension_key: "web_search_request", quantity: 1,
      rate_amount: 10, rate_quantity: 1000, cost: 0.01, currency: "EUR",
      cost_status: LlmCostTracker::Charges::CostStatus::COMPLETE,
      price_key: "service_charges.openai.web_search_request"
    )
    allow(LlmCostTracker::Logging).to receive(:warn)
    calculation = described_class.for(
      provider: "openai", model: "snap-model",
      tokens: { input_tokens: 1_000_000 }, pricing_mode: nil, line_items: [eur_line]
    )

    expect(calculation.cost.total).to eq(BigDecimal("2.0"))
    expect(calculation.snapshot.fetch("rates")).to have_key("input")
    expect(calculation.snapshot.fetch("rates").keys).not_to include("service_charges.openai.web_search_request")
    expect(LlmCostTracker::Logging).to have_received(:warn).with(include("currency mismatch"))
  end

  it "does not add a service rate on top of a provider-billed total that already includes it" do
    Tempfile.create(["lct-openrouter", ".yml"]) do |file|
      file.write({ "service_charges" => { "openrouter" => { "web_search_request" => 4.0 } } }.to_yaml)
      file.close
      LlmCostTracker.configure { |c| c.pricing.file = file.path }
      line_items = [
        LlmCostTracker::Charges::LineItem.build(dimension_key: "web_search_request", quantity: 1),
        LlmCostTracker::Charges::LineItem.build(dimension_key: "billed_request", quantity: 1, rate_amount: 0.0245,
                                                cost: 0.0245, price_source: "provider_response")
      ]
      calculation = described_class.for(
        provider: "openrouter", model: "openai/gpt-4o:online",
        tokens: { input_tokens: 1_000, output_tokens: 200 }, pricing_mode: nil, line_items: line_items
      )

      expect(calculation.cost.total).to eq(BigDecimal("0.0245"))
    end
  end

  it "leaves a provider-billed call unknown when the billed line carries no cost" do
    line_items = [LlmCostTracker::Charges::LineItem.build(dimension_key: "billed_request", quantity: 1)]
    calculation = described_class.for(
      provider: "openrouter", model: "openai/gpt-4o",
      tokens: { input_tokens: 1_000, output_tokens: 200 }, pricing_mode: nil, line_items: line_items
    )

    expect([calculation.cost, calculation.cost_status]).to eq([nil, LlmCostTracker::Charges::CostStatus::UNKNOWN])
  end
end
