# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Configuration do
  let(:config) { described_class.new }

  SAMPLE_VALUES = {
    %i[budgets monthly] => 500,
    %i[budgets daily] => 50,
    %i[budgets per_call] => 2,
    %i[budgets exceeded_behavior] => :raise,
    %i[budgets totals_source] => :cache,
    %i[budgets on_exceeded] => ->(_payload) {},
    %i[tags default] => { "team" => "core" },
    %i[tags max_count] => 7,
    %i[tags max_value_bytesize] => 64,
    %i[tags redacted_keys] => %w[token],
    %i[tags report_breakdown_keys] => %w[feature],
    %i[pricing file] => "config/prices.json",
    %i[pricing overrides] => { "demo" => { "input" => 1.0 } },
    %i[pricing unknown_model_behavior] => :raise,
    %i[ingestion mode] => :async,
    %i[ingestion pool_size] => 4,
    %i[capture request_stream_usage] => false,
    %i[capture openai_compatible_providers] => { "gw.example.com" => "internal" }
  }.freeze

  def silencing_deprecations
    previous = LlmCostTracker.deprecator.behavior
    LlmCostTracker.deprecator.behavior = :silence
    yield
  ensure
    LlmCostTracker.deprecator.behavior = previous
  end

  describe "sections" do
    it "exposes one object per namespace" do
      expect(config.budgets).to be_a(described_class::Budgets)
      expect(config.tags).to be_a(described_class::Tags)
      expect(config.pricing).to be_a(described_class::Pricing)
      expect(config.ingestion).to be_a(described_class::Ingestion)
      expect(config.capture).to be_a(described_class::Capture)
    end

    it "ships the documented defaults" do
      expect(config.ingestion.mode).to eq(:inline)
      expect(config.budgets.exceeded_behavior).to eq(:notify)
      expect(config.pricing.unknown_model_behavior).to eq(:warn)
      expect(config.tags.max_count).to eq(50)
      expect(config.capture.request_stream_usage).to be(true)
      expect(config.budgets.totals_source).to eq(:ledger)
    end
  end

  describe "enum attributes" do
    it "accepts a documented value" do
      config.ingestion.mode = :async
      expect(config.ingestion.mode).to eq(:async)
    end

    it "names the namespaced option when rejecting an unknown value" do
      expect { config.ingestion.mode = :bogus }
        .to raise_error(LlmCostTracker::Error, /Unknown ingestion\.mode: :bogus/)
    end

    it "normalizes nil back to the default" do
      config.ingestion.mode = :async
      config.ingestion.mode = nil
      expect(config.ingestion.mode).to eq(:inline)
    end
  end

  describe "pricing.overrides=" do
    it "raises a friendly error naming the namespaced option" do
      expect { config.pricing.overrides = { "demo" => { "input" => nil } } }
        .to raise_error(LlmCostTracker::Error, /invalid pricing\.overrides/)
    end
  end

  describe "deprecated flat names" do
    described_class::DEPRECATED_OPTIONS.each do |old_name, spec|
      next if spec[:to].nil? || spec[:writer_only] || spec[:cast]

      section, new_name = spec[:to]
      it "routes #{old_name} to #{section}.#{new_name}" do
        value = SAMPLE_VALUES.fetch([section, new_name])
        via_section = described_class.new
        via_section.public_send(section).public_send(:"#{new_name}=", value)
        expected = via_section.public_send(section).public_send(new_name)

        silencing_deprecations { config.public_send(:"#{old_name}=", value) }

        expect(config.public_send(section).public_send(new_name)).to eq(expected)
        expect(silencing_deprecations { config.public_send(old_name) }).to eq(expected)
      end
    end

    it "warns with the replacement name" do
      warnings = []
      previous = LlmCostTracker.deprecator.behavior
      LlmCostTracker.deprecator.behavior = ->(message, *) { warnings << message }
      config.monthly_budget = 10
      LlmCostTracker.deprecator.behavior = previous

      expect(warnings.first).to include("config.budgets.monthly")
    end

    it "maps the cache_rollups boolean onto the budgets.totals_source strategy" do
      silencing_deprecations { config.cache_rollups = true }
      expect(config.budgets.totals_source).to eq(:cache)
      expect(silencing_deprecations { config.cache_rollups }).to be(true)

      silencing_deprecations { config.cache_rollups = false }
      expect(config.budgets.totals_source).to eq(:ledger)
      expect(silencing_deprecations { config.cache_rollups }).to be(false)
    end

    it "refuses to write a removed option after finalize!" do
      config.finalize!

      expect { silencing_deprecations { config.log_level = :debug } }.to raise_error(FrozenError)
    end

    it "warns that log_level has no effect and keeps it out of the generated initializer" do
      warnings = []
      previous = LlmCostTracker.deprecator.behavior
      LlmCostTracker.deprecator.behavior = ->(message, *) { warnings << message }
      config.log_level = :debug
      LlmCostTracker.deprecator.behavior = previous

      expect(warnings.first).to include("has no effect")
    end

    it "still assigns ingestion.mode through the flat writer while the reader returns the section" do
      silencing_deprecations { config.ingestion = :async }

      expect(config.ingestion.mode).to eq(:async)
      expect(config.ingestion).to be_a(described_class::Ingestion)
      expect(config.capture).to be_a(described_class::Capture)
    end
  end

  describe "deprecator" do
    it "registers before the host app's config/initializers run" do
      names = Rails.application.initializers.map { |initializer| initializer.name.to_s }

      expect(names.index("llm_cost_tracker.deprecator")).to be < names.rindex("load_config_initializers")
    end

    it "is registered with Rails so host apps can configure or silence it" do
      registered = Rails.application.deprecators.instance_variable_get(:@deprecators)

      expect(registered[:llm_cost_tracker]).to be(LlmCostTracker.deprecator)
    end
  end

  describe "#finalize!" do
    it "freezes section collections" do
      config.tags.default = { "team" => "core" }
      config.capture.openai_compatible_providers["GW.Example.com"] = :internal
      config.finalize!

      expect(config.tags.default).to be_frozen
      expect(config.capture.openai_compatible_providers).to include("gw.example.com" => "internal")
      expect { config.budgets.monthly = 1 }.to raise_error(FrozenError)
      expect { config.tags.redacted_keys = [] }.to raise_error(FrozenError)
    end
  end
end
