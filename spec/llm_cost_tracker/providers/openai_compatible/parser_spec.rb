# frozen_string_literal: true

require "spec_helper"
require "uri"

RSpec.describe LlmCostTracker::Providers::OpenaiCompatible::Parser do
  subject(:parser) { described_class.new }

  let(:openrouter_chat_url) { URI::HTTPS.build(host: "openrouter.ai", path: "/api/v1/chat/completions").to_s }
  let(:openrouter_models_url) { URI::HTTPS.build(host: "openrouter.ai", path: "/api/v1/models").to_s }
  let(:deepseek_v1_chat_url) { URI::HTTPS.build(host: "api.deepseek.com", path: "/v1/chat/completions").to_s }
  let(:deepseek_chat_url) { URI::HTTPS.build(host: "api.deepseek.com", path: "/chat/completions").to_s }
  let(:groq_chat_url) { URI::HTTPS.build(host: "api.groq.com", path: "/openai/v1/chat/completions").to_s }
  let(:groq_responses_url) { URI::HTTPS.build(host: "api.groq.com", path: "/openai/v1/responses").to_s }
  let(:configured_responses_url) { URI::HTTPS.build(host: "llm.example.com", path: "/v1/responses").to_s }
  let(:configured_chat_url) { URI::HTTPS.build(host: "llm.example.com", path: "/v1/chat/completions").to_s }

  it "uses the shared OpenAI usage extractor without inheriting from the OpenAI parser" do
    expect(described_class.superclass).to eq(LlmCostTracker::Parsers::Base)
  end

  describe "#match?" do
    it_behaves_like "a parser with invalid URL handling"

    it "matches OpenRouter chat completions URLs" do
      expect(described_class.match?(openrouter_chat_url)).to be true
    end

    it "matches DeepSeek chat completions URLs" do
      expect(described_class.match?(deepseek_v1_chat_url)).to be true
    end

    it "matches Groq OpenAI-compatible URLs" do
      expect(described_class.match?(groq_chat_url)).to be true
      expect(described_class.match?(groq_responses_url)).to be true
    end

    it "matches configured OpenAI-compatible hosts" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      expect(described_class.match?(configured_responses_url)).to be true
    end

    it "matches configured OpenAI-compatible hosts case-insensitively" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["LLM.EXAMPLE.COM"] = "internal_gateway"
      end

      expect(described_class.match?(configured_responses_url)).to be true
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
      expect(described_class.match?(configured_chat_url)).to be false
    end

    it "does not match unrelated paths on configured hosts" do
      expect(described_class.match?(openrouter_models_url)).to be false
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
        request_url: openrouter_chat_url,
        request_body: { model: "openai/gpt-4o-mini" }.to_json,
        response_status: 200,
        response_body: {
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
      expect(result.token_usage.input_tokens).to eq(25)
      expect(result.token_usage.output_tokens).to eq(10)
      expect(result.token_usage.total_tokens).to eq(35)
    end

    it "extracts DeepSeek usage and provider name" do
      result = parser.parse(
        request_url: deepseek_chat_url,
        request_body: { model: "deepseek-chat" }.to_json,
        response_status: 200,
        response_body: {
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
      expect(result.token_usage.input_tokens).to eq(300)
      expect(result.token_usage.output_tokens).to eq(80)
    end

    it "extracts Groq usage, cached input, reasoning tokens, and service tier" do
      result = parser.parse(
        request_url: groq_chat_url,
        request_body: { model: "openai/gpt-oss-20b", service_tier: "flex" }.to_json,
        response_status: 200,
        response_body: {
          id: "chatcmpl-groq",
          model: "openai/gpt-oss-20b",
          service_tier: "flex",
          usage: {
            prompt_tokens: 4_641,
            completion_tokens: 1_817,
            total_tokens: 6_458,
            prompt_tokens_details: {
              cached_tokens: 4_608
            },
            completion_tokens_details: {
              reasoning_tokens: 128
            }
          }
        }.to_json
      )

      expect(result.provider).to eq("groq")
      expect(result.provider_response_id).to eq("chatcmpl-groq")
      expect(result.pricing_mode).to eq(:flex)
      expect(result.model).to eq("openai/gpt-oss-20b")
      expect(result.token_usage.input_tokens).to eq(33)
      expect(result.token_usage.cache_read_input_tokens).to eq(4_608)
      expect(result.token_usage.output_tokens).to eq(1_817)
      expect(result.token_usage.hidden_output_tokens).to eq(128)
      expect(result.token_usage.total_tokens).to eq(6_458)
    end

    it "uses the configured provider name for custom compatible hosts" do
      LlmCostTracker.configure do |config|
        config.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      result = parser.parse(
        request_url: configured_responses_url,
        request_body: { model: "custom-chat" }.to_json,
        response_status: 200,
        response_body: {
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
      expect(result.token_usage.input_tokens).to eq(150)
      expect(result.token_usage.output_tokens).to eq(42)
    end
  end

  describe "#parse_stream" do
    let(:request_body) do
      { model: "deepseek-chat", stream: true, stream_options: { include_usage: true } }.to_json
    end

    let(:final_usage_event) do
      {
        event: nil,
        data: { "usage" => { "prompt_tokens" => 30, "completion_tokens" => 10, "total_tokens" => 40 } }
      }
    end

    it "extracts DeepSeek streaming usage and provider name" do
      events = [
        { event: nil, data: { "id" => "deepseek-1", "model" => "deepseek-chat" } },
        final_usage_event
      ]

      result = parser.parse_stream(
        request_url: deepseek_v1_chat_url,
        request_body: request_body,
        response_status: 200,
        events: events
      )

      expect(result.provider).to eq("deepseek")
      expect(result.model).to eq("deepseek-chat")
      expect(result.usage_source).to eq("stream_final")
      expect(result.token_usage.input_tokens).to eq(30)
      expect(result.token_usage.output_tokens).to eq(10)
      expect(result.provider_response_id).to eq("deepseek-1")
    end

    it "extracts Groq streaming usage" do
      events = [
        { event: nil, data: { "id" => "groq-x", "model" => "llama-3.3-70b-versatile" } },
        final_usage_event
      ]

      result = parser.parse_stream(
        request_url: groq_chat_url,
        request_body: { model: "llama-3.3-70b-versatile", stream: true,
                        stream_options: { include_usage: true } }.to_json,
        response_status: 200,
        events: events
      )

      expect(result.provider).to eq("groq")
      expect(result.usage_source).to eq("stream_final")
      expect(result.token_usage.input_tokens).to eq(30)
      expect(result.token_usage.output_tokens).to eq(10)
    end

    it "extracts OpenRouter streaming usage" do
      events = [
        { event: nil, data: { "id" => "or-y", "model" => "openrouter/auto" } },
        final_usage_event
      ]

      result = parser.parse_stream(
        request_url: openrouter_chat_url,
        request_body: { model: "openrouter/auto", stream: true,
                        stream_options: { include_usage: true } }.to_json,
        response_status: 200,
        events: events
      )

      expect(result.provider).to eq("openrouter")
      expect(result.token_usage.input_tokens).to eq(30)
    end

    it "warns and records unknown usage when an OpenAI-compatible chat stream omits the final usage chunk" do
      events = [
        { event: nil, data: { "id" => "groq-x", "model" => "llama-3.3-70b-versatile" } }
      ]

      expect(LlmCostTracker::Logging).to receive(:warn).with(/stream_options.*include_usage/).once
      result = parser.parse_stream(
        request_url: groq_chat_url,
        request_body: { model: "llama-3.3-70b-versatile", stream: true }.to_json,
        response_status: 200,
        events: events
      )

      expect(result.usage_source).to eq("unknown")
    end
  end
end
