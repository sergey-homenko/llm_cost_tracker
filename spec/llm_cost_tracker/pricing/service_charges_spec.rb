# frozen_string_literal: true

require "spec_helper"
require "tempfile"
require "yaml"

RSpec.describe LlmCostTracker::Pricing::Registry do
  before { described_class.reset! }

  it "resolves every non-token dimension key to itself, unshadowed by an earlier suffix match" do
    LlmCostTracker::Usage::Catalog.all.reject(&:token_key).each do |dimension|
      expect(described_class.send(:parse_dimension_key, dimension.key)).to eq([dimension, nil]),
        -> { "#{dimension.key} is shadowed in parse_dimension_key by an earlier dimension" }
    end
  end

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
        expect(described_class.instance_variable_get(:@file_rates)).not_to be_nil

        described_class.reset!
        expect(described_class.instance_variable_get(:@file_rates)).to be_nil
      end
    end
  end

  describe ".builtin_rates" do
    it "loads bundled service charge rates once" do
      expect(described_class.builtin_rates.dig("anthropic", "web_search_request", :default)).to include(
        amount: BigDecimal("10.0"),
        quantity: BigDecimal("1000"),
        currency: "USD",
        source_key: "web_search_request"
      )
      expect(described_class.builtin_rates).to eq(described_class.builtin_rates)
    end

    it "uses billing dimension keys for bundled tool prices" do
      registry = YAML.safe_load_file(LlmCostTracker::Pricing::Registry::DEFAULT_PRICES_PATH, aliases: false)
      tool_keys = registry.fetch("service_charges").values.flat_map(&:keys)
      dimensions = LlmCostTracker::Usage::Catalog.all.filter_map do |dimension|
        dimension.key if dimension.token_key.nil?
      end

      expect(tool_keys - dimensions).to eq([])
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
              tiers: {},
              default: {
                amount: BigDecimal("10.0"),
                quantity: BigDecimal("1000"),
                currency: "USD",
                source_key: "web_search_request"
              }
            },
            "container_session" => {
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
            "web_search_request" => {
              tiers: {
                "priority" => {
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

    it "raises a readable error for unknown service charge dimensions" do
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
        end.to raise_error(LlmCostTracker::Error, /unknown billing dimension/)
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
      expect(described_class.rates_from_registry({ "models" => {} }, context: "spec")).to eq({})
    end

    it "rejects non-hash service charge sections" do
      expect do
        described_class.rates_from_registry({ "service_charges" => [] }, context: "spec")
      end.to raise_error(ArgumentError, /service_charges must be a hash/)
    end

    it "rejects non-hash provider sections" do
      expect do
        described_class.rates_from_registry({ "service_charges" => { "openai" => [] } }, context: "spec")
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
          },
          context: "spec"
        )
      ).to eq(
        "anthropic" => {
          "web_search_request" => {
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
          },
          context: "spec"
        )
      ).to eq(
        "openai" => {
          "web_search_request" => {
            tiers: {
              "priority" => {
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
          },
          context: "spec"
        )
      end.to raise_error(ArgumentError, /unknown billing dimension/)
    end
  end

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
      allow(described_class).to receive(:builtin_rates).and_return(
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
      allow(described_class).to receive(:builtin_rates).and_return(
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
