# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Billing::Components do
  it "keeps token-priced components aligned with TokenUsage" do
    token_keys = described_class::TOKEN_PRICED.map(&:token_key)
    missing = token_keys - LlmCostTracker::TokenUsage.members

    expect(missing).to be_empty
  end

  it "exposes cost_key for every token-priced component" do
    described_class::TOKEN_PRICED.each do |component|
      expect(component.cost_key).to be_a(Symbol)
    end
  end

  it "has unique component keys" do
    keys = described_class::REGISTRY.map(&:key)

    expect(keys).to eq(keys.uniq)
  end

  it "loads identity fields from the YAML registry" do
    grounding = described_class::BY_KEY.fetch(:grounding_request)

    expect(grounding).to have_attributes(
      kind: :grounding_request,
      direction: :neither,
      modality: :text,
      cache_state: :none,
      unit: :request,
      category: :tool,
      token_key: nil,
      cost_key: nil
    )
  end

  describe ".build" do
    it "raises when a required field is missing in the YAML entry" do
      expect { described_class.build(key: :broken) }
        .to raise_error(LlmCostTracker::Error,
                        include("components.yml entry missing kind"))
    end
  end
end
