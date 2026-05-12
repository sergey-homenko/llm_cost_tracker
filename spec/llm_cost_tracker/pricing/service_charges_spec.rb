# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "yaml"

RSpec.describe LlmCostTracker::Pricing::ServiceCharges do
  before { described_class.reset! }

  describe ".reset!" do
    it "drops cached builtin rates so the next read reloads from disk" do
      first = described_class.builtin_rates
      described_class.reset!
      expect(described_class.instance_variable_get(:@builtin_rates)).to be_nil
      second = described_class.builtin_rates
      expect(second).to eq(first)
      expect(second.object_id).not_to eq(first.object_id)
    end

    it "drops the file_rates cache between configurations" do
      Tempfile.create(["lct-charges", ".yml"]) do |file|
        file.write({ "service_charges" => { "openai" => { "web_search_request" => 25.0 } } }.to_yaml)
        file.close
        described_class.file_rates(file.path)
        expect(described_class.instance_variable_get(:@file_rates_cache)).not_to be_nil

        described_class.reset!
        expect(described_class.instance_variable_get(:@file_rates_cache)).to be_nil
      end
    end
  end

  describe ".builtin_rates" do
    it "loads bundled service charge rates once" do
      expect(described_class.builtin_rates.dig("anthropic", :web_search_request, :default)).to include(
        amount: BigDecimal("10.0"),
        quantity: BigDecimal("1000"),
        currency: "USD",
        source_key: "web_search_request"
      )
      expect(described_class.builtin_rates).to eq(described_class.builtin_rates)
    end

    it "uses billing component keys for bundled tool prices" do
      registry = YAML.safe_load_file(LlmCostTracker::Pricing::Registry::DEFAULT_PRICES_PATH, aliases: false)
      tool_keys = registry.fetch("service_charges").values.flat_map(&:keys)
      components = LlmCostTracker::Billing::Components::REGISTRY.filter_map do |component|
        component.key.name if component.token_key.nil?
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
            web_search_request: {
              tiers: {},
              default: {
                amount: BigDecimal("10.0"),
                quantity: BigDecimal("1000"),
                currency: "USD",
                source_key: "web_search_request"
              }
            },
            container_session: {
              tiers: {},
              default: {
                amount: BigDecimal("0.03"),
                quantity: BigDecimal("1"),
                currency: "USD",
                source_key: "container_session"
              }
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
            web_search_request: {
              tiers: {
                priority: {
                  amount: BigDecimal("12.0"),
                  quantity: BigDecimal("1000"),
                  currency: "USD",
                  source_key: "priority_web_search_request"
                }
              }
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

    it "rejects an infinite service-charge amount so a literal 'Infinity' in a custom prices file cannot poison downstream cost math" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(%({"service_charges":{"openai":{"web_search_request":"Infinity"}},"models":{}}))
        file.close

        expect do
          described_class.file_rates(file.path)
        end.to raise_error(LlmCostTracker::Error, /amount.*must be finite/)
      end
    end
  end

  describe ".rates_from_registry" do
    it "ignores registries without tool price sections" do
      expect(described_class.rates_from_registry({ "models" => {} })).to eq({})
    end

    it "rejects non-hash service charge sections" do
      expect do
        described_class.rates_from_registry({ "service_charges" => [] })
      end.to raise_error(ArgumentError, /service_charges must be a hash/)
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
          web_search_request: {
            tiers: {},
            default: {
              amount: BigDecimal("10.0"),
              quantity: BigDecimal("1000"),
              currency: "USD",
              source_key: "web_search_request"
            }
          }
        }
      )
    end

    it "builds rates from symbol service charge keys" do
      expect(
        described_class.rates_from_registry(
          {
            "service_charges" => {
              "openai" => {
                priority_web_search_request: 12.0
              }
            }
          }
        )
      ).to eq(
        "openai" => {
          web_search_request: {
            tiers: {
              priority: {
                amount: BigDecimal("12.0"),
                quantity: BigDecimal("1000"),
                currency: "USD",
                source_key: "priority_web_search_request"
              }
            }
          }
        }
      )
    end

    it "rejects tier keys without tier names" do
      expect do
        described_class.rates_from_registry(
          {
            "service_charges" => {
              "openai" => {
                "_web_search_request" => 10.0
              }
            }
          }
        )
      end.to raise_error(ArgumentError, /unknown billing component/)
    end
  end

end
