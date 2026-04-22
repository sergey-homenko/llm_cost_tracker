# frozen_string_literal: true

require "spec_helper"
require "uri"

RSpec.describe LlmCostTracker::Parsers::OpenaiCompatible do
  subject(:parser) { described_class.new }

  let(:openrouter_chat_url) { URI::HTTPS.build(host: "openrouter.ai", path: "/api/v1/chat/completions").to_s }
  let(:openrouter_models_url) { URI::HTTPS.build(host: "openrouter.ai", path: "/api/v1/models").to_s }
  let(:deepseek_v1_chat_url) { URI::HTTPS.build(host: "api.deepseek.com", path: "/v1/chat/completions").to_s }
  let(:deepseek_chat_url) { URI::HTTPS.build(host: "api.deepseek.com", path: "/chat/completions").to_s }
  let(:configured_responses_url) { URI::HTTPS.build(host: "llm.example.com", path: "/v1/responses").to_s }
  let(:configured_chat_url) { URI::HTTPS.build(host: "llm.example.com", path: "/v1/chat/completions").to_s }

  it "uses the shared OpenAI usage extractor without inheriting from the OpenAI parser" do
    expect(described_class.superclass).to eq(LlmCostTracker::Parsers::Base)
  end

  describe "#match?" do
    it "matches OpenRouter chat completions URLs" do
      expect(parser.match?(openrouter_chat_url)).to be true
    end

    it "matches DeepSeek chat completions URLs" do
      expect(parser.match?(deepseek_v1_chat_url)).to be true
    end

    it "matches configured OpenAI-compatible hosts" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      expect(parser.match?(configured_responses_url)).to be true
    end

    it "matches configured OpenAI-compatible hosts case-insensitively" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["LLM.EXAMPLE.COM"] = "internal_gateway"
      end

      expect(parser.match?(configured_responses_url)).to be true
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
      expect(parser.match?(configured_chat_url)).to be false
    end

    it "does not match unrelated paths on configured hosts" do
      expect(parser.match?(openrouter_models_url)).to be false
    end
  end

  describe "#parse" do
    it_behaves_like "a parser with common usage failure handling",
                    url: URI::HTTPS.build(host: "openrouter.ai", path: "/api/v1/chat/completions").to_s,
                    request_body: { model: "openai/gpt-4o-mini" }.to_json,
                    response_body: { error: "rate limited" }.to_json,
                    missing_usage_body: { model: "openai/gpt-4o-mini" }.to_json

    it "extracts OpenRouter usage and provider name" do
      result = parser.parse(
        openrouter_chat_url,
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
        deepseek_chat_url,
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
        configured_responses_url,
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
