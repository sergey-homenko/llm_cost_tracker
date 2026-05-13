# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/providers/gemini/model_families"

RSpec.describe LlmCostTracker::Providers::Gemini::ModelFamilies do
  describe ".per_query_grounding?" do
    it "matches Gemini 3+ models that bill grounding per query" do
      %w[gemini-3 gemini-3-pro gemini-4 gemini-10 gemini-15-pro].each do |model|
        expect(described_class.per_query_grounding?(model)).to be(true), "expected #{model} to bill per query"
      end
    end

    it "rejects Gemini 1.x / 2.x and non-Gemini models" do
      %w[gemini-1.5-pro gemini-2.0-flash gpt-4o claude-sonnet-4-6].each do |model|
        expect(described_class.per_query_grounding?(model)).to be(false), "expected #{model} to not bill per query"
      end
    end
  end
end
