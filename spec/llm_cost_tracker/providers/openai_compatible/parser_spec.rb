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

    it "matches xAI and Mistral hosts, regional ones included" do
      urls = %w[api.x.ai us.api.x.ai api.mistral.ai api.eu.mistral.ai api.us.mistral.ai].map do |host|
        URI::HTTPS.build(host: host, path: "/v1/chat/completions").to_s
      end

      expect(urls.map { |url| [described_class.match?(url), parser.provider_for(url)] })
        .to eq([[true, "xai"]] * 2 + [[true, "mistral"]] * 3)
    end

    it "lets a configured mapping replace a built-in one" do
      LlmCostTracker.configure { |config| config.capture.openai_compatible_providers["API.X.AI"] = "grok_gateway" }

      expect(parser.provider_for(URI::HTTPS.build(host: "api.x.ai", path: "/v1/responses").to_s)).to eq("grok_gateway")
    end

    it "matches configured OpenAI-compatible hosts" do
      LlmCostTracker.configure do |config|
        config.capture.openai_compatible_providers["llm.example.com"] = "internal_gateway"
      end

      expect(described_class.match?(configured_responses_url)).to be true
    end

    it "matches configured OpenAI-compatible hosts case-insensitively" do
      LlmCostTracker.configure do |config|
        config.capture.openai_compatible_providers["LLM.EXAMPLE.COM"] = "internal_gateway"
      end

      expect(described_class.match?(configured_responses_url)).to be true
    end

    it "normalizes configured OpenAI-compatible host keys after configure" do
      LlmCostTracker.configure do |config|
        config.capture.openai_compatible_providers["LLM.EXAMPLE.COM"] = "internal_gateway"
      end

      expect(LlmCostTracker.configuration.capture.openai_compatible_providers)
        .to include("llm.example.com" => "internal_gateway")
      expect(LlmCostTracker.configuration.capture.openai_compatible_providers).not_to have_key("LLM.EXAMPLE.COM")
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
      expect(result.pricing_mode).to eq("flex")
      expect(result.model).to eq("openai/gpt-oss-20b")
      expect(result.token_usage.input_tokens).to eq(33)
      expect(result.token_usage.cache_read_input_tokens).to eq(4_608)
      expect(result.token_usage.output_tokens).to eq(1_817)
      expect(result.token_usage.hidden_output_tokens).to eq(128)
      expect(result.token_usage.total_tokens).to eq(6_458)
    end

    it "uses the configured provider name for custom compatible hosts" do
      LlmCostTracker.configure do |config|
        config.capture.openai_compatible_providers["llm.example.com"] = "internal_gateway"
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

    it "reads Groq stream usage from x_groq.usage, raw or wrapped by the OpenAI SDK stream helper" do
      x_groq = { "x_groq" => { "id" => "req_1", "usage" => final_usage_event[:data]["usage"] } }
      results = [x_groq, { "chunk" => x_groq }].map do |data|
        parser.parse_stream(
          request_url: groq_chat_url,
          request_body: { model: "llama-3.3-70b-versatile", stream: true }.to_json,
          response_status: 200,
          events: [{ event: nil, data: { "id" => "groq-x", "model" => "llama-3.3-70b-versatile" } },
                   { event: nil, data: data }]
        )
      end

      expect(results.map(&:usage_source)).to eq(%w[stream_final stream_final])
      expect(results.map { |result| result.token_usage.input_tokens }).to eq([30, 30])
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

  describe "xAI and Mistral pricing tiers" do
    before do
      LlmCostTracker.configure do |config|
        config.pricing.overrides = {
          "xai/grok-4.7" => { input: 2.0, cache_read_input: 0.5, output: 6.0, data_residency_input: 2.2,
                              data_residency_output: 6.6 },
          "xai/grok-4.3" => { input: 1.25, output: 2.5 },
          "mistral/mistral-medium-latest" => { input: 1.5, output: 7.5, data_residency_input: 1.65,
                                               data_residency_output: 8.25 },
          "mistral/mistral-small-latest" => { input: 0.15, output: 0.6 }
        }
      end
    end

    def chat_mode(host, model, **fields)
      usage = { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }.merge(fields.delete(:usage).to_h)
      parser.parse(
        request_url: URI::HTTPS.build(host: host, path: "/v1/chat/completions").to_s,
        request_body: { model: model }.to_json,
        response_status: 200,
        response_body: { id: "chatcmpl-1", model: model, usage: usage, **fields }.to_json
      ).pricing_mode
    end

    it "prices regional hosts at data residency rates only for models that have them" do
      expect(chat_mode("us.api.x.ai", "grok-4.7")).to eq("data_residency")
      expect(chat_mode("us.api.x.ai", "grok-4.3")).to be_nil
      expect(chat_mode("api.x.ai", "grok-4.7")).to be_nil
      expect(chat_mode("api.eu.mistral.ai", "mistral-medium-latest")).to eq("data_residency")
      expect(chat_mode("api.eu.mistral.ai", "mistral-small-latest")).to be_nil
    end

    it "reads xAI's served tier from the response and Mistral's from usage.service_tier" do
      expect(chat_mode("api.x.ai", "grok-4.7", service_tier: "priority")).to eq("priority")
      expect(chat_mode("api.mistral.ai", "mistral-medium-latest", usage: { service_tier: "priority" })).to eq("priority")
      expect(chat_mode("api.mistral.ai", "mistral-medium-latest", usage: { service_tier: "standard" })).to be_nil
    end

    it "prices xAI reasoning tokens at the output rate, since xAI counts them outside completion and output tokens" do
      usages = {
        "/v1/chat/completions" => { prompt_tokens: 32, completion_tokens: 9, total_tokens: 135,
                                    prompt_tokens_details: { cached_tokens: 6 },
                                    completion_tokens_details: { reasoning_tokens: 94 } },
        "/v1/responses" => { input_tokens: 32, output_tokens: 9, total_tokens: 151,
                             input_tokens_details: { cached_tokens: 8 }, output_tokens_details: { reasoning_tokens: 110 } }
      }
      costs = usages.map do |path, usage|
        event = parser.parse(
          request_url: URI::HTTPS.build(host: "api.x.ai", path: path).to_s,
          request_body: { model: "grok-4.7" }.to_json,
          response_status: 200,
          response_body: { id: "xai-1", model: "grok-4.7", usage: usage }.to_json
        )
        LlmCostTracker::Pricing.cost_for(provider: "xai", model: "grok-4.7", tokens: event.token_usage).total
      end

      expect(costs).to eq(%w[0.000673 0.000766].map { |total| BigDecimal(total) })
    end

    it "reads Mistral's served tier from a stream's final usage chunk" do
      usage = { "prompt_tokens" => 30, "completion_tokens" => 10, "total_tokens" => 40, "service_tier" => "priority" }
      result = parser.parse_stream(
        request_url: URI::HTTPS.build(host: "api.mistral.ai", path: "/v1/chat/completions").to_s,
        request_body: { model: "mistral-medium-latest", stream: true, service_tier: "auto" }.to_json,
        response_status: 200,
        events: [{ event: nil, data: { "id" => "cmpl-1", "model" => "mistral-medium-latest" } },
                 { event: nil, data: { "id" => "cmpl-1", "choices" => [], "usage" => usage } }]
      )

      expect(result).to have_attributes(provider: "mistral", pricing_mode: "priority", usage_source: "stream_final")
    end
  end
end
