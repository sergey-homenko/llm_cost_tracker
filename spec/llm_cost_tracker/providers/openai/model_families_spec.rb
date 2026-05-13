# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/providers/openai/model_families"

RSpec.describe LlmCostTracker::Providers::Openai::ModelFamilies do
  describe ".data_residency?" do
    it "matches gpt-5.4 / gpt-5.5 and their nano/mini/pro/codex variants with optional dated suffix" do
      %w[
        gpt-5.4 gpt-5.5 gpt-5.4-mini gpt-5.5-nano gpt-5.4-pro
        gpt-5.4-codex gpt-5.4-codex-mini gpt-5.5-codex-max
        gpt-5.4-2026-04-01
      ].each do |model|
        expect(described_class.data_residency?(model)).to be(true), "expected #{model} to be data-residency-eligible"
      end
    end

    it "rejects older gpt-5 and non-gpt-5 models" do
      %w[gpt-5 gpt-5.1 gpt-5.3 gpt-4o gpt-image-1 claude-sonnet-4-6].each do |model|
        expect(described_class.data_residency?(model)).to be(false), "expected #{model} to not be data-residency-eligible"
      end
    end
  end

  describe ".image_output?" do
    it "matches gpt-image-* models" do
      %w[gpt-image-1 gpt-image-1-mini gpt-image-1.5 gpt-image-2].each do |model|
        expect(described_class.image_output?(model)).to be true
      end
    end

    it "rejects non-image models" do
      expect(described_class.image_output?("gpt-4o")).to be false
      expect(described_class.image_output?(nil)).to be false
    end
  end

  describe ".character_billed_tts?" do
    it "matches only tts-1 and tts-1-hd" do
      expect(described_class.character_billed_tts?("tts-1")).to be true
      expect(described_class.character_billed_tts?("tts-1-hd")).to be true
    end

    it "does not match the gpt-4o-mini-tts SDK-only model" do
      expect(described_class.character_billed_tts?("gpt-4o-mini-tts")).to be false
    end
  end

  describe ".reasoning?" do
    it "treats gpt-5 family and o-series as reasoning models" do
      %w[gpt-5 gpt-5-mini gpt-5.1 gpt-5.4-pro o1 o1-mini o3 o4].each do |model|
        expect(described_class.reasoning?(model)).to be(true), "expected #{model} to be reasoning"
      end
    end

    it "excludes gpt-5-chat / gpt-5.1-chat-latest variants" do
      %w[gpt-5-chat gpt-5-chat-latest gpt-5.1-chat-latest gpt-5.2-chat-latest].each do |model|
        expect(described_class.reasoning?(model)).to be(false), "expected #{model} to not be reasoning"
      end
    end

    it "excludes non-OpenAI and non-reasoning OpenAI models" do
      %w[gpt-4o gpt-4o-mini gpt-image-1 claude-sonnet-4-6].each do |model|
        expect(described_class.reasoning?(model)).to be false
      end
    end

    it "is false for nil / empty strings" do
      expect(described_class.reasoning?(nil)).to be false
      expect(described_class.reasoning?("")).to be false
    end
  end
end
