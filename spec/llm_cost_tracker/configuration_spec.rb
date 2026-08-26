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

  describe "budgets.per_tag=" do
    it "normalizes windows and per-rule options into one entry" do
      handler = ->(_payload) {}
      config.budgets.per_tag = { tenant_id: { monthly: 1000, weekly: 300, behavior: :notify, on_exceeded: handler } }

      expect(config.budgets.per_tag).to eq(
        "tenant_id" => { windows: { monthly: 1000, weekly: 300 }, behavior: :notify, on_exceeded: handler }
      )
    end

    it "leaves the per-rule options nil so the global settings apply" do
      config.budgets.per_tag = { tenant_id: { monthly: 1000 } }

      expect(config.budgets.per_tag.fetch("tenant_id"))
        .to eq(windows: { monthly: 1000 }, behavior: nil, on_exceeded: nil)
    end

    it "reads per-rule options written with string keys" do
      handler = ->(_payload) {}
      config.budgets.per_tag = {
        "tenant_id" => { "monthly" => 5, "behavior" => :block_requests, "on_exceeded" => handler }
      }

      expect(config.budgets.per_tag.fetch("tenant_id"))
        .to eq(windows: { monthly: BigDecimal("5") }, behavior: :block_requests, on_exceeded: handler)
    end

    it "stores limits as BigDecimal so a numeric string cannot blow up the request path" do
      config.budgets.per_tag = { tenant_id: { monthly: "5.50" } }

      limit = config.budgets.per_tag.fetch("tenant_id")[:windows][:monthly]

      expect(limit).to eq(BigDecimal("5.50"))
      expect(BigDecimal("6") >= limit).to be(true)
    end

    it "rejects an unknown per-rule behavior" do
      expect { config.budgets.per_tag = { tenant_id: { monthly: 1, behavior: :explode } } }
        .to raise_error(LlmCostTracker::Error, /Unknown budgets\.per_tag.*behavior: :explode/)
    end

    it "rejects an entry with options but no window" do
      expect { config.budgets.per_tag = { tenant_id: { behavior: :notify } } }
        .to raise_error(LlmCostTracker::Error, /needs at least one of/)
    end

    it "accepts several tag keys, each with its own windows" do
      config.budgets.per_tag = { tenant_id: { monthly: 1000 }, feature: { daily: 5 } }

      expect(config.budgets.per_tag.keys).to eq(%w[tenant_id feature])
      expect(config.budgets.per_tag.fetch("feature")[:windows]).to eq(daily: 5)
    end

    it "rejects an unknown window" do
      expect { config.budgets.per_tag = { tenant_id: { hourly: 1 } } }
        .to raise_error(LlmCostTracker::Error, /Unknown budgets\.per_tag.*window: :hourly/)
    end

    it "rejects a limit that is not a positive number" do
      expect { config.budgets.per_tag = { tenant_id: { monthly: 0 } } }
        .to raise_error(LlmCostTracker::Error, /must be a positive number/)
    end

    it "rejects a tag key the ledger would refuse to store" do
      expect { config.budgets.per_tag = { "not a key!" => { monthly: 1 } } }
        .to raise_error(LlmCostTracker::Error)
    end

    it "freezes the declaration on finalize!" do
      config.budgets.per_tag = { tenant_id: { monthly: 1 } }
      config.finalize!

      expect(config.budgets.per_tag).to be_frozen
      expect { config.budgets.per_tag = {} }.to raise_error(FrozenError)
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
