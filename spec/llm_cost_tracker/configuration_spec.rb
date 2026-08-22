# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Configuration do
  let(:config) { described_class.new }

  SAMPLE_VALUES = {
    %i[budgets monthly] => 500,
    %i[budgets daily] => 50,
    %i[budgets per_call] => 2,
    %i[budgets exceeded_behavior] => :raise,
    %i[budgets on_exceeded] => ->(_payload) {},
    %i[tags default] => { "team" => "core" },
    %i[tags max_count] => 7,
    %i[tags max_value_bytesize] => 64,
    %i[tags redacted_keys] => %w[token],
    %i[tags breakdown_keys] => %w[feature],
    %i[pricing file] => "config/prices.json",
    %i[pricing overrides] => { "demo" => { "input" => 1.0 } },
    %i[pricing unknown_behavior] => :raise,
    %i[ingestion mode] => :async,
    %i[ingestion pool_size] => 4
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
    end

    it "ships the documented defaults" do
      expect(config.ingestion.mode).to eq(:inline)
      expect(config.budgets.exceeded_behavior).to eq(:notify)
      expect(config.pricing.unknown_behavior).to eq(:warn)
      expect(config.tags.max_count).to eq(50)
      expect(config.cache_rollups).to be(false)
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
    described_class::DEPRECATED_ATTRIBUTES.each do |old_name, (section, new_name)|
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
    end
  end

  describe "#finalize!" do
    it "freezes section collections" do
      config.tags.default = { "team" => "core" }
      config.finalize!

      expect(config.tags.default).to be_frozen
      expect { config.budgets.monthly = 1 }.to raise_error(FrozenError)
      expect { config.tags.redacted_keys = [] }.to raise_error(FrozenError)
    end
  end
end
