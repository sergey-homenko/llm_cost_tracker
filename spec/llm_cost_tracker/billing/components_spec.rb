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
      token_key: nil,
      cost_key: nil,
      rate_basis: :per_1k_requests
    )
  end

  it "defaults the rate_basis from the unit when YAML omits the field" do
    expect(described_class::BY_KEY.fetch(:input).rate_basis).to eq(:per_million_tokens)
    expect(described_class::BY_KEY.fetch(:container_session).rate_basis).to eq(:per_session)
    expect(described_class::BY_KEY.fetch(:code_execution_hour).rate_basis).to eq(:per_hour)
  end

  describe ".build" do
    it "raises when a required field is missing in the YAML entry" do
      expect { described_class.build(key: :broken) }
        .to raise_error(LlmCostTracker::Error,
                        include("components.yml entry missing kind"))
    end

    it "raises when rate_basis is not in the supported enum" do
      attributes = {
        key: :weird, kind: :weird, direction: :neither, modality: :text,
        cache_state: :none, unit: :widget, rate_basis: :per_widget
      }

      expect { described_class.build(attributes) }
        .to raise_error(LlmCostTracker::Error, /unknown rate_basis :per_widget/)
    end

    it "raises when an unknown unit has no rate_basis to fall back on" do
      attributes = {
        key: :unknown_unit, kind: :unknown_unit, direction: :neither, modality: :text,
        cache_state: :none, unit: :widget
      }

      expect { described_class.build(attributes) }
        .to raise_error(LlmCostTracker::Error, /needs rate_basis for unit :widget/)
    end
  end
end
