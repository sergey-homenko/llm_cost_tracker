# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Parsers::Openai do
  subject(:parser) { described_class.new }

  describe "#match?" do
    it "matches OpenAI chat completions URL" do
      expect(parser.match?("https://api.openai.com/v1/chat/completions")).to be true
    end

    it "matches OpenAI embeddings URL" do
      expect(parser.match?("https://api.openai.com/v1/embeddings")).to be true
    end

    it "matches OpenAI Responses URL" do
      expect(parser.match?("https://api.openai.com/v1/responses")).to be true
    end

    it "does not match OpenAI response retrieval URLs" do
      expect(parser.match?("https://api.openai.com/v1/responses/resp_123")).to be false
    end

    it "does not match other URLs" do
      expect(parser.match?("https://api.anthropic.com/v1/messages")).to be false
    end
  end

  describe "#parse" do
    let(:request_body) { { model: "gpt-4o", messages: [] }.to_json }

    let(:response_body) do
      {
        model: "gpt-4o",
        usage: {
          prompt_tokens: 150,
          completion_tokens: 42,
          total_tokens: 192
        }
      }.to_json
    end

    it_behaves_like "a parser with common usage failure handling",
                    url: "https://api.openai.com/v1/chat/completions",
                    request_body: { model: "gpt-4o" }.to_json,
                    response_body: { error: "rate limited" }.to_json,
                    missing_usage_body: { model: "gpt-4o" }.to_json

    it "extracts token usage from a successful response" do
      result = parser.parse(
        "https://api.openai.com/v1/chat/completions",
        request_body,
        200,
        {
          id: "chatcmpl_123",
          model: "gpt-4o",
          usage: {
            prompt_tokens: 150,
            completion_tokens: 42,
            total_tokens: 192
          }
        }.to_json
      )

      expect(result).to be_a(LlmCostTracker::ParsedUsage)
      expect(result.provider).to eq("openai")
      expect(result.model).to eq("gpt-4o")
      expect(result.input_tokens).to eq(150)
      expect(result.output_tokens).to eq(42)
      expect(result.provider_response_id).to eq("chatcmpl_123")
    end

    it "extracts token usage from a Responses API response" do
      response_body = {
        id: "resp_123",
        model: "gpt-5-mini",
        usage: {
          input_tokens: 150,
          input_tokens_details: { cached_tokens: 100 },
          output_tokens: 42,
          total_tokens: 192
        }
      }.to_json

      result = parser.parse(
        "https://api.openai.com/v1/responses",
        { model: "gpt-5-mini" }.to_json,
        200,
        response_body
      )

      expect(result.provider).to eq("openai")
      expect(result.model).to eq("gpt-5-mini")
      expect(result.input_tokens).to eq(150)
      expect(result.output_tokens).to eq(42)
      expect(result.cached_input_tokens).to eq(100)
      expect(result.provider_response_id).to eq("resp_123")
    end

    it "tags non-streaming usage with a :response source" do
      result = parser.parse(
        "https://api.openai.com/v1/chat/completions",
        request_body,
        200,
        response_body
      )

      expect(result.stream).to be false
      expect(result.usage_source).to eq(:response)
    end
  end

  describe "#streaming_request?" do
    it "detects a stream:true body" do
      expect(parser.streaming_request?("https://api.openai.com/v1/chat/completions",
                                       '{"model":"gpt-4o","stream":true}')).to be true
    end

    it "ignores non-streaming bodies" do
      expect(parser.streaming_request?("https://api.openai.com/v1/chat/completions",
                                       '{"model":"gpt-4o"}')).to be false
    end
  end

  describe "#parse_stream" do
    let(:request_body) { { model: "gpt-4o", stream: true }.to_json }

    it "extracts usage from a final chunk carrying the usage hash" do
      events = [
        { event: nil, data: { "model" => "gpt-4o", "choices" => [{ "delta" => { "content" => "hi" } }] } },
        { event: nil, data: { "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } } }
      ]

      result = parser.parse_stream(
        "https://api.openai.com/v1/chat/completions",
        request_body,
        200,
        events
      )

      expect(result.provider).to eq("openai")
      expect(result.model).to eq("gpt-4o")
      expect(result.input_tokens).to eq(12)
      expect(result.output_tokens).to eq(3)
      expect(result.total_tokens).to eq(15)
      expect(result.stream).to be true
      expect(result.usage_source).to eq(:stream_final)
      expect(result.provider_response_id).to be_nil
    end

    it "extracts response ids from chat completion stream chunks" do
      events = [
        {
          event: nil,
          data: { "id" => "chatcmpl_456", "model" => "gpt-4o", "choices" => [{ "delta" => { "content" => "hi" } }] }
        },
        { event: nil, data: { "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } } }
      ]

      result = parser.parse_stream(
        "https://api.openai.com/v1/chat/completions",
        request_body,
        200,
        events
      )

      expect(result.provider_response_id).to eq("chatcmpl_456")
    end

    it "extracts response ids from Responses API stream events" do
      events = [
        {
          event: nil,
          data: { "type" => "response.created", "response" => { "id" => "resp_456", "model" => "gpt-5-mini" } }
        },
        { event: nil, data: { "usage" => { "input_tokens" => 12, "output_tokens" => 3, "total_tokens" => 15 } } }
      ]

      result = parser.parse_stream(
        "https://api.openai.com/v1/responses",
        { model: "gpt-5-mini", stream: true }.to_json,
        200,
        events
      )

      expect(result.provider_response_id).to eq("resp_456")
    end

    it "returns an unknown-usage ParsedUsage when no usage chunk arrives" do
      events = [
        { event: nil, data: { "model" => "gpt-4o", "choices" => [{ "delta" => { "content" => "hi" } }] } }
      ]

      result = parser.parse_stream(
        "https://api.openai.com/v1/chat/completions",
        request_body,
        200,
        events
      )

      expect(result.stream).to be true
      expect(result.usage_source).to eq(:unknown)
      expect(result.input_tokens).to eq(0)
      expect(result.output_tokens).to eq(0)
      expect(result.provider_response_id).to be_nil
    end

    it "returns nil on non-200 responses" do
      expect(parser.parse_stream("https://api.openai.com/v1/chat/completions", request_body, 500, [])).to be_nil
    end
  end
end
