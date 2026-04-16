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

    it "extracts token usage from a successful response" do
      result = parser.parse(
        "https://api.openai.com/v1/chat/completions",
        request_body,
        200,
        response_body
      )

      expect(result[:provider]).to eq("openai")
      expect(result[:model]).to eq("gpt-4o")
      expect(result[:input_tokens]).to eq(150)
      expect(result[:output_tokens]).to eq(42)
    end

    it "returns nil for non-200 responses" do
      result = parser.parse(
        "https://api.openai.com/v1/chat/completions",
        request_body,
        429,
        { error: "rate limited" }.to_json
      )

      expect(result).to be_nil
    end

    it "returns nil when usage is missing" do
      result = parser.parse(
        "https://api.openai.com/v1/chat/completions",
        request_body,
        200,
        { model: "gpt-4o" }.to_json
      )

      expect(result).to be_nil
    end
  end
end
