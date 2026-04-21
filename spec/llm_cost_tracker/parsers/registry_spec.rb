# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Parsers::Registry do
  describe ".find_for_provider" do
    it "finds the OpenAI-compatible parser for configured provider names" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      parser = described_class.find_for_provider("internal_gateway")

      expect(parser).to be_a(LlmCostTracker::Parsers::OpenaiCompatible)
    end

    it "lets registered parsers opt into provider lookup via provider_names" do
      parser_class = Class.new(LlmCostTracker::Parsers::Base) do
        def provider_names
          %w[acme]
        end

        def match?(_url)
          false
        end

        def parse(*)
          nil
        end
      end
      parser = parser_class.new

      described_class.register(parser)

      expect(described_class.find_for_provider("acme")).to eq(parser)
    end
  end
end
