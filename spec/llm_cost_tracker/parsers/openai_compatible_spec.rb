# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Parsers::OpenaiCompatible do
  subject(:parser) { described_class.new }

  it "uses the shared OpenAI usage extractor without inheriting from the OpenAI parser" do
    expect(described_class.superclass).to eq(LlmCostTracker::Parsers::Base)
  end

  describe "#match?" do
    it "matches OpenRouter chat completions URLs" do
      expect(parser.match?("https://openrouter.ai/api/v1/chat/completions")).to be true
    end

    it "matches DeepSeek chat completions URLs" do
      expect(parser.match?("https://api.deepseek.com/v1/chat/completions")).to be true
    end

    it "matches configured OpenAI-compatible hosts" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      expect(parser.match?("https://llm.example.com/v1/responses")).to be true
    end

    it "matches configured OpenAI-compatible hosts case-insensitively" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["LLM.EXAMPLE.COM"] = "internal_gateway"
      end

      expect(parser.match?("https://llm.example.com/v1/responses")).to be true
    end

    it "normalizes configured OpenAI-compatible host keys after configure" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["LLM.EXAMPLE.COM"] = "internal_gateway"
      end

      expect(LlmCostTracker.configuration.openai_compatible_providers)
        .to include("llm.example.com" => "internal_gateway")
      expect(LlmCostTracker.configuration.openai_compatible_providers).not_to have_key("LLM.EXAMPLE.COM")
    end

    it "does not match unknown hosts" do
      expect(parser.match?("https://llm.example.com/v1/chat/completions")).to be false
    end

    it "does not match unrelated paths on configured hosts" do
      expect(parser.match?("https://openrouter.ai/api/v1/models")).to be false
    end
  end

  describe "#parse" do
    it_behaves_like "a parser with common usage failure handling",
                    url: "https://openrouter.ai/api/v1/chat/completions",
                    request_body: { model: "openai/gpt-4o-mini" }.to_json,
                    response_body: { error: "rate limited" }.to_json,
                    missing_usage_body: { model: "openai/gpt-4o-mini" }.to_json

    it "extracts OpenRouter usage and provider name" do
      result = parser.parse(
        "https://openrouter.ai/api/v1/chat/completions",
        { model: "openai/gpt-4o-mini" }.to_json,
        200,
        {
          model: "openai/gpt-4o-mini",
          usage: {
            prompt_tokens: 25,
            completion_tokens: 10,
            total_tokens: 35
          }
        }.to_json
      )

      expect(result.provider).to eq("openrouter")
      expect(result.model).to eq("openai/gpt-4o-mini")
      expect(result.input_tokens).to eq(25)
      expect(result.output_tokens).to eq(10)
      expect(result.total_tokens).to eq(35)
    end

    it "extracts DeepSeek usage and provider name" do
      result = parser.parse(
        "https://api.deepseek.com/chat/completions",
        { model: "deepseek-chat" }.to_json,
        200,
        {
          model: "deepseek-chat",
          usage: {
            prompt_tokens: 300,
            completion_tokens: 80,
            total_tokens: 380
          }
        }.to_json
      )

      expect(result.provider).to eq("deepseek")
      expect(result.model).to eq("deepseek-chat")
      expect(result.input_tokens).to eq(300)
      expect(result.output_tokens).to eq(80)
    end

    it "uses the configured provider name for custom compatible hosts" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      result = parser.parse(
        "https://llm.example.com/v1/responses",
        { model: "custom-chat" }.to_json,
        200,
        {
          model: "custom-chat",
          usage: {
            input_tokens: 150,
            output_tokens: 42,
            total_tokens: 192
          }
        }.to_json
      )

      expect(result.provider).to eq("internal_gateway")
      expect(result.model).to eq("custom-chat")
      expect(result.input_tokens).to eq(150)
      expect(result.output_tokens).to eq(42)
    end
  end
end
