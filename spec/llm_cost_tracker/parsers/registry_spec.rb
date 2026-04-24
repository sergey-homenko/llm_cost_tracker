# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Parsers::Registry do
  def build_parser_class(provider_name:, match: false)
    Class.new(LlmCostTracker::Parsers::Base) do
      define_method(:provider_names) { [provider_name] }
      define_method(:match?) { |_url| match }
      define_method(:parse) { |*| nil }
    end
  end

  describe ".register" do
    it "accepts parser classes and instantiates them" do
      parser_class = build_parser_class(provider_name: "acme")

      parser = described_class.register(parser_class)

      expect(parser).to be_a(parser_class)
      expect(described_class.find_for_provider("acme")).to eq(parser)
    end

    it "prioritizes registered parsers for URL lookup" do
      parser_class = build_parser_class(provider_name: "override", match: true)
      parser = described_class.register(parser_class)

      expect(described_class.find_for("https://api.openai.com/v1/responses")).to eq(parser)
    end
  end

  describe ".find_for_provider" do
    it "finds the OpenAI-compatible parser for configured provider names" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      parser = described_class.find_for_provider("internal_gateway")

      expect(parser).to be_a(LlmCostTracker::Parsers::OpenaiCompatible)
    end

    it "picks up configured provider names after the parser was already initialized" do
      expect(described_class.find_for_provider("openai_compatible")).to be_a(LlmCostTracker::Parsers::OpenaiCompatible)

      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      expect(described_class.find_for_provider("internal_gateway")).to be_a(LlmCostTracker::Parsers::OpenaiCompatible)
    end

    it "lets registered parsers opt into provider lookup via provider_names" do
      parser = build_parser_class(provider_name: "acme").new

      described_class.register(parser)

      expect(described_class.find_for_provider("acme")).to eq(parser)
    end

    it "matches provider names case-insensitively" do
      parser = build_parser_class(provider_name: "acme").new

      described_class.register(parser)

      expect(described_class.find_for_provider("ACME")).to eq(parser)
    end

    it "normalizes non-string provider names from custom parsers" do
      parser_class = Class.new(LlmCostTracker::Parsers::Base) do
        def provider_names
          [:acme]
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
