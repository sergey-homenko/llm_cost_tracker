# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe LlmCostTracker::Pricing::ServiceRates do
  before { LlmCostTracker::Pricing::Registry.reset! }

  describe ".charge_rate" do
    it "returns nil when no service charge rate exists" do
      expect(described_class.charge_rate(provider: "gemini", dimension: "grounding_request", pricing_mode: nil)).to be_nil
    end

    it "returns nil when the provider is missing" do
      expect(described_class.charge_rate(provider: nil, dimension: "web_search_request", pricing_mode: nil)).to be_nil
    end

    it "loads provider service charge rates from the configured prices file" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(
          {
            service_charges: {
              openai: {
                web_search_request: 10.0
              }
            },
            models: {}
          }.to_json
        )
        file.close
        LlmCostTracker.configure { |config| config.prices_file = file.path }

        rate = described_class.charge_rate(provider: "openai", dimension: "web_search_request", pricing_mode: nil)

        expect(rate).to have_attributes(
          amount: BigDecimal("10.0"),
          quantity: BigDecimal("1000"),
          currency: "USD",
          source: "prices_file",
          source_key: "service_charges.openai.web_search_request"
        )
        expect(rate.source_version).to be_a(String)
      end
    end

    it "uses tier-specific provider service charge rates" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(
          {
            service_charges: {
              openai: {
                web_search_request: 10.0,
                priority_web_search_request: 12.0
              }
            },
            models: {}
          }.to_json
        )
        file.close
        LlmCostTracker.configure { |config| config.prices_file = file.path }

        rate = described_class.charge_rate(provider: "openai", dimension: "web_search_request", pricing_mode: "priority")

        expect(rate).to have_attributes(
          amount: BigDecimal("12.0"),
          source_key: "service_charges.openai.priority_web_search_request"
        )
      end
    end

    it "carries the prices_file metadata currency through to the service charge rate" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(
          {
            metadata: { currency: "EUR" },
            service_charges: { openai: { web_search_request: 10.0 } },
            models: {}
          }.to_json
        )
        file.close
        LlmCostTracker.configure { |config| config.prices_file = file.path }

        rate = described_class.charge_rate(provider: "openai", dimension: "web_search_request", pricing_mode: nil)

        expect(rate).to have_attributes(amount: BigDecimal("10.0"), currency: "EUR", source: "prices_file")
      end
    end

    it "falls back from combined pricing modes to dimension tier rates" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(
          {
            service_charges: {
              openai: {
                web_search_request: 10.0,
                batch_web_search_request: 8.0
              }
            },
            models: {}
          }.to_json
        )
        file.close
        LlmCostTracker.configure { |config| config.prices_file = file.path }

        rate = described_class.charge_rate(provider: "openai", dimension: "web_search_request",
                                           pricing_mode: "batch_data_residency")

        expect(rate).to have_attributes(
          amount: BigDecimal("8.0"),
          source_key: "service_charges.openai.batch_web_search_request"
        )
      end
    end

    it "falls back from combined pricing modes to the default dimension rate" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(
          {
            service_charges: {
              openai: {
                web_search_request: 10.0
              }
            },
            models: {}
          }.to_json
        )
        file.close
        LlmCostTracker.configure { |config| config.prices_file = file.path }

        rate = described_class.charge_rate(provider: "openai", dimension: "web_search_request",
                                           pricing_mode: "batch_data_residency")

        expect(rate).to have_attributes(
          amount: BigDecimal("10.0"),
          source_key: "service_charges.openai.web_search_request"
        )
      end
    end

    it "ignores unrelated tier-specific service charge rates" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(
          {
            service_charges: {
              openai: {
                web_search_request: 10.0,
                priority_web_search_request: 12.0
              }
            },
            models: {}
          }.to_json
        )
        file.close
        LlmCostTracker.configure { |config| config.prices_file = file.path }

        rate = described_class.charge_rate(provider: "openai", dimension: "web_search_request",
                                           pricing_mode: "batch_data_residency")

        expect(rate).to have_attributes(
          amount: BigDecimal("10.0"),
          source_key: "service_charges.openai.web_search_request"
        )
      end
    end

    it "falls back to bundled service charge rates" do
      allow(LlmCostTracker::Pricing::Registry).to receive(:builtin_rates).and_return(
        "anthropic" => {
          "web_search_request" => {
            tiers: {},
            default: {
              amount: BigDecimal("5.0"),
              quantity: BigDecimal("1000"),
              currency: "USD",
              source_key: "web_search_request"
            }
          }
        }
      )

      rate = described_class.charge_rate(provider: "anthropic", dimension: "web_search_request", pricing_mode: nil)

      expect(rate).to have_attributes(
        amount: BigDecimal("5.0"),
        quantity: BigDecimal("1000"),
        source: "bundled",
        source_key: "service_charges.anthropic.web_search_request",
        source_version: LlmCostTracker::VERSION
      )
    end

    it "accepts provider symbols at the call boundary" do
      allow(LlmCostTracker::Pricing::Registry).to receive(:builtin_rates).and_return(
        "anthropic" => {
          "web_search_request" => {
            tiers: {},
            default: {
              amount: BigDecimal("5.0"),
              quantity: BigDecimal("1000"),
              currency: "USD",
              source_key: "web_search_request"
            }
          }
        }
      )

      rate = described_class.charge_rate(provider: :anthropic, dimension: "web_search_request", pricing_mode: nil)

      expect(rate).to have_attributes(source: "bundled")
    end

    it "rejects unknown billing dimensions" do
      expect do
        described_class.charge_rate(provider: "openai", dimension: :unknown_tool, pricing_mode: nil)
      end.to raise_error(LlmCostTracker::Error, /Unknown billing dimension/)
    end
  end
end
