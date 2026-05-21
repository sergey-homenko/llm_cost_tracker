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

  it "raises when an enabled integration cannot satisfy its install contract" do
    stub_const("RubyLLM::VERSION", "1.13.0")
    allow(Gem.loaded_specs).to receive(:[]).and_call_original
    allow(Gem.loaded_specs).to receive(:[]).with("ruby_llm").and_return(nil)

    expect do
      LlmCostTracker.configure { |c| c.instrument(:ruby_llm) }
    end.to raise_error(
      LlmCostTracker::Error,
      /ruby_llm integration cannot be installed: ruby_llm >= 1\.14\.1 is required, detected 1\.13\.0/
    )
  end

  it "reports incompatible integrations with invalid SDK version constants" do
    stub_const("RubyLLM::VERSION", "not-a-version")
    allow(Gem.loaded_specs).to receive(:[]).and_call_original
    allow(Gem.loaded_specs).to receive(:[]).with("ruby_llm").and_return(nil)

    check = described_class.checks([:ruby_llm]).first
    expect(check.status).to eq(:warn)
    expect(check.message).to include("ruby_llm >= 1.14.1 is required, but ruby_llm is not loaded")
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

  it "rejects unknown integrations" do
    expect do
      LlmCostTracker.configure { |c| c.instrument(:gemini) }
    end.to raise_error(LlmCostTracker::Error, /Unknown integration: :gemini/)
  end

  it "rejects unknown integration fetches" do
    expect do
      described_class.fetch(:gemini)
    end.to raise_error(LlmCostTracker::Error, /Unknown integration: :gemini/)
  end

  it "installs idempotently" do
    LlmCostTracker.configure { |c| c.instrument(:openai) }
    described_class.install!
    check = described_class.checks([:openai]).first
    expect(check.status).to eq(:ok)
  end
end
