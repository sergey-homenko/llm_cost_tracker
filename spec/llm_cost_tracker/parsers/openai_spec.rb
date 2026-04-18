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
        response_body
      )

      expect(result).to be_a(LlmCostTracker::ParsedUsage)
      expect(result[:provider]).to eq("openai")
      expect(result[:model]).to eq("gpt-4o")
      expect(result[:input_tokens]).to eq(150)
      expect(result[:output_tokens]).to eq(42)
    end

    it "extracts token usage from a Responses API response" do
      response_body = {
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

      expect(result[:provider]).to eq("openai")
      expect(result[:model]).to eq("gpt-5-mini")
      expect(result[:input_tokens]).to eq(150)
      expect(result[:output_tokens]).to eq(42)
      expect(result[:cached_input_tokens]).to eq(100)
    end
  end
end
