# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "yaml"

RSpec.describe LlmCostTracker::Pricing::ServiceCharges do
  before do
    if described_class.instance_variable_defined?(:@file_rates_cache)
      described_class.remove_instance_variable(:@file_rates_cache)
    end
    if described_class.instance_variable_defined?(:@builtin_rates)
      described_class.remove_instance_variable(:@builtin_rates)
    end
  end

  describe ".builtin_rates" do
    it "loads bundled service charge rates once" do
      expect(described_class.builtin_rates.dig("anthropic", "web_search_request")).to include(
        amount: BigDecimal("10.0"),
        quantity: BigDecimal("1000"),
        currency: "USD"
      )
      expect(described_class.builtin_rates).to eq(described_class.builtin_rates)
    end

    it "uses billing component keys for bundled tool prices" do
      registry = YAML.safe_load_file(LlmCostTracker::Pricing::Registry::DEFAULT_PRICES_PATH, aliases: false)
      tool_keys = registry.fetch("service_charges").values.flat_map(&:keys)
      components = LlmCostTracker::Billing::Components::REGISTRY.filter_map do |component|
        component.key.to_s if component.token_key.nil?
      end

      expect(tool_keys - components).to eq([])
    end
  end

  describe ".file_rates" do
    it "loads service charge rates from a local prices file" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({
          service_charges: {
            openai: {
              web_search_request: 10.0,
              container_session: 0.03
            }
          },
          models: {}
        }.to_json)
        file.close

        expect(described_class.file_rates(file.path)).to eq(
          "openai" => {
            "web_search_request" => {
              amount: BigDecimal("10.0"),
              quantity: BigDecimal("1000"),
              currency: "USD"
            },
            "container_session" => {
              amount: BigDecimal("0.03"),
              quantity: BigDecimal("1"),
              currency: "USD"
            }
          }
        )
        expect(described_class.file_rates(file.path)).to eq(described_class.file_rates(file.path))
      end
    end

    it "loads tier-specific service charge rates from a local prices file" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({
          service_charges: {
            openai: {
              priority_web_search_request: 12.0
            }
          },
          models: {}
        }.to_json)
        file.close

        expect(described_class.file_rates(file.path)).to eq(
          "openai" => {
            "priority_web_search_request" => {
              amount: BigDecimal("12.0"),
              quantity: BigDecimal("1000"),
              currency: "USD"
            }
          }
        )
      end
    end

    it "raises a readable error for non-hash provider sections" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({
          service_charges: {
            openai: []
          },
          models: {}
        }.to_json)
        file.close

        expect do
          described_class.file_rates(file.path)
        end.to raise_error(LlmCostTracker::Error, /service_charges\.openai must be a hash/)
      end
    end

    it "raises a readable error for unknown service charge components" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({
          service_charges: {
            openai: {
              web_serch_request: 10.0
            }
          },
          models: {}
        }.to_json)
        file.close

        expect do
          described_class.file_rates(file.path)
        end.to raise_error(LlmCostTracker::Error, /unknown billing component/)
      end
    end

    it "raises a readable error for negative service charge rates" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({
          service_charges: {
            openai: {
              web_search_request: -1.0
            }
          },
          models: {}
        }.to_json)
        file.close

        expect do
          described_class.file_rates(file.path)
        end.to raise_error(LlmCostTracker::Error, /amount.*must be non-negative/)
      end
    end
  end

  describe ".rates_from_registry" do
    it "ignores registries without tool price sections" do
      expect(described_class.rates_from_registry({ "models" => {} })).to eq({})
    end

    it "rejects non-hash provider sections" do
      expect do
        described_class.rates_from_registry({ "service_charges" => { "openai" => [] } })
      end.to raise_error(ArgumentError, /service_charges\.openai must be a hash/)
    end

    it "builds rates from provider service charge sections" do
      expect(
        described_class.rates_from_registry(
          {
            "service_charges" => {
              "anthropic" => {
                "web_search_request" => 10.0
              }
            }
          }
        )
      ).to eq(
        "anthropic" => {
          "web_search_request" => {
            amount: BigDecimal("10.0"),
            quantity: BigDecimal("1000"),
            currency: "USD"
          }
        }
      )
    end
  end

end
