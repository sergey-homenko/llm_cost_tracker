# frozen_string_literal: true

require "spec_helper"
require "anthropic"
require "openai"
require "ruby_llm"

RSpec.describe LlmCostTracker::Integrations do
  before do
    allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_return(true)
    allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
  end

  it "reports installed RubyLLM integration check after patching" do
    LlmCostTracker.configure { |c| c.instrument(:ruby_llm) }

    check = described_class.checks([:ruby_llm]).first
    expect(check.status).to eq(:ok)
    expect(check.message).to eq("ruby_llm integration installed")
  end

  it "raises when minimum_version exceeds the actually installed gem version" do
    ruby_llm = LlmCostTracker::Integrations::RubyLlm
    installed = Gem.loaded_specs["ruby_llm"].version
    too_high = "#{installed.segments[0] + 1}.0.0"
    original = ruby_llm.minimum_version
    ruby_llm.instance_variable_set(:@minimum_version, too_high)

    expect do
      LlmCostTracker.configure { |c| c.instrument(:ruby_llm) }
    end.to raise_error(
      LlmCostTracker::Error,
      /ruby_llm >= #{Regexp.escape(too_high)} is required, detected #{Regexp.escape(installed.to_s)}/
    )
  ensure
    ruby_llm.instance_variable_set(:@minimum_version, original)
  end

  it "reports the SDK gem as not loaded when Gem.loaded_specs has no entry under integration_name" do
    ghost = Module.new do
      extend LlmCostTracker::Integrations::Base
      def self.integration_name = :totally_made_up_gem_name_xyz
      minimum_version "1.0.0"
    end

    expect(ghost.send(:version_problems))
      .to include(match(/totally_made_up_gem_name_xyz >= 1\.0\.0 is required, but .* is not loaded/))
  end

  it "resolves the installed version via Gem.loaded_specs for the default gem_version" do
    expect(LlmCostTracker::Integrations::RubyLlm.gem_version)
      .to eq(Gem.loaded_specs["ruby_llm"].version)
    expect(LlmCostTracker::Integrations::Anthropic.gem_version)
      .to eq(Gem.loaded_specs["anthropic"].version)
    expect(LlmCostTracker::Integrations::Openai.gem_version)
      .to eq(Gem.loaded_specs["openai"].version)
  end

  it "reports missing enabled SDK integrations in doctor" do
    allow(Gem.loaded_specs).to receive(:[]).and_call_original
    allow(Gem.loaded_specs).to receive(:[]).with("anthropic").and_return(nil)
    hide_const("Anthropic")

    expect(described_class.checks([:anthropic]).first.message)
      .to include("anthropic integration cannot be installed")
  end

  it "warns when :ruby_llm and a Faraday-parser integration are enabled together" do
    allow(LlmCostTracker::Logging).to receive(:warn)
    described_class.warn_double_instrumentation(%i[ruby_llm openai])
    expect(LlmCostTracker::Logging).to have_received(:warn).with(/ruby_llm.*together with.*openai/)
  end

  it "does not warn when only :ruby_llm is enabled" do
    allow(LlmCostTracker::Logging).to receive(:warn)
    described_class.warn_double_instrumentation(%i[ruby_llm])
    expect(LlmCostTracker::Logging).not_to have_received(:warn)
  end

  it "expands the all instrumentation alias" do
    LlmCostTracker.configure { |c| c.instrument(:all) }
    expect(LlmCostTracker.configuration.instrumented_integrations).to contain_exactly(:openai, :anthropic, :ruby_llm)
    expect { LlmCostTracker.configuration.instrumented_integrations.add(:gemini) }.to raise_error(FrozenError)
  end

  it "warns and skips unknown integrations on install instead of raising" do
    LlmCostTracker.configure { |c| c.instrument(:gemini) }
    allow(LlmCostTracker::Logging).to receive(:warn)

    expect { described_class.install! }.not_to raise_error
    expect(LlmCostTracker::Logging).to have_received(:warn).with(/Unknown integration: :gemini/)
  end

  it "returns nil from fetch for an unknown integration so install! can skip it" do
    expect(described_class.fetch(:gemini)).to be_nil
  end

  it "installs idempotently" do
    LlmCostTracker.configure { |c| c.instrument(:openai) }
    described_class.install!
    check = described_class.checks([:openai]).first
    expect(check.status).to eq(:ok)
  end
end
