# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Parsers::Anthropic do
  subject(:parser) { described_class.new }

  describe "#match?" do
    it "matches Anthropic messages URL" do
      expect(parser.match?("https://api.anthropic.com/v1/messages")).to be true
    end

    it "does not match OpenAI URLs" do
      expect(parser.match?("https://api.openai.com/v1/chat/completions")).to be false
    end
  end

  describe "#parse" do
    let(:request_body) { { model: "claude-sonnet-4-6", messages: [] }.to_json }

    let(:response_body) do
      {
        model: "claude-sonnet-4-6",
        usage: {
          input_tokens: 200,
          output_tokens: 80,
          cache_read_input_tokens: 50,
          cache_creation_input_tokens: 10
        }
      }.to_json
    end

    it_behaves_like "a parser with common usage failure handling",
                    url: "https://api.anthropic.com/v1/messages",
                    request_body: { model: "claude-sonnet-4-6" }.to_json,
                    response_body: { error: "rate limited" }.to_json,
                    missing_usage_body: { model: "claude-sonnet-4-6" }.to_json

    it "extracts token usage including cache tokens" do
      result = parser.parse(
        "https://api.anthropic.com/v1/messages",
        request_body,
        200,
        response_body
      )

      expect(result.provider).to eq("anthropic")
      expect(result.model).to eq("claude-sonnet-4-6")
      expect(result.input_tokens).to eq(200)
      expect(result.output_tokens).to eq(80)
      expect(result.total_tokens).to eq(340)
      expect(result.cache_read_input_tokens).to eq(50)
      expect(result.cache_creation_input_tokens).to eq(10)
      expect(result.stream).to be false
      expect(result.usage_source).to eq(:response)
    end
  end

  describe "#parse_stream" do
    let(:request_body) { { model: "claude-sonnet-4-6", stream: true }.to_json }

    it "merges message_start usage with message_delta cumulative totals" do
      events = [
        { event: "message_start", data: {
          "type" => "message_start",
          "message" => {
            "model" => "claude-sonnet-4-6",
            "usage" => { "input_tokens" => 120, "output_tokens" => 1, "cache_read_input_tokens" => 40 }
          }
        } },
        { event: "message_delta", data: {
          "type" => "message_delta",
          "usage" => { "output_tokens" => 64 }
        } }
      ]

      result = parser.parse_stream(
        "https://api.anthropic.com/v1/messages",
        request_body,
        200,
        events
      )

      expect(result.provider).to eq("anthropic")
      expect(result.model).to eq("claude-sonnet-4-6")
      expect(result.input_tokens).to eq(120)
      expect(result.output_tokens).to eq(64)
      expect(result.total_tokens).to eq(120 + 64 + 40)
      expect(result.cache_read_input_tokens).to eq(40)
      expect(result.stream).to be true
      expect(result.usage_source).to eq(:stream_final)
    end

    it "returns unknown usage when no message events are present" do
      result = parser.parse_stream(
        "https://api.anthropic.com/v1/messages",
        request_body,
        200,
        []
      )

      expect(result.stream).to be true
      expect(result.usage_source).to eq(:unknown)
      expect(result.input_tokens).to eq(0)
      expect(result.model).to eq("claude-sonnet-4-6")
    end
  end
end
