# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Parsers::Gemini do
  subject(:parser) { described_class.new }

  describe "#match?" do
    it "matches Gemini URLs case-insensitively" do
      expect(parser.match?("https://GENERATIVELANGUAGE.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"))
        .to be true
    end

    it "matches Gemini streaming generation URLs" do
      expect(parser.match?("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent"))
        .to be true
    end

    it "does not match unrelated Gemini endpoints" do
      expect(parser.match?("https://generativelanguage.googleapis.com/v1beta/models")).to be false
    end
  end

  describe "#parse" do
    it_behaves_like "a parser with common usage failure handling",
                    url: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
                    request_body: nil,
                    response_body: { error: "rate limited" }.to_json,
                    missing_usage_body: { model: "gemini-2.5-flash" }.to_json

    it "counts thinking tokens as output tokens" do
      result = parser.parse(
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
        nil,
        200,
        {
          usageMetadata: {
            promptTokenCount: 100,
            candidatesTokenCount: 25,
            thoughtsTokenCount: 50,
            totalTokenCount: 175
          }
        }.to_json
      )

      expect(result.provider).to eq("gemini")
      expect(result.model).to eq("gemini-2.5-flash")
      expect(result.input_tokens).to eq(100)
      expect(result.output_tokens).to eq(75)
      expect(result.total_tokens).to eq(175)
      expect(result.stream).to be false
      expect(result.usage_source).to eq(:response)
    end
  end

  describe "#streaming_request?" do
    it "flags the streamGenerateContent path as streaming" do
      expect(parser.streaming_request?(
               "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent",
               nil
             )).to be true
    end

    it "does not flag generateContent as streaming" do
      expect(parser.streaming_request?(
               "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
               nil
             )).to be false
    end
  end

  describe "#parse_stream" do
    let(:url) { "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent" }

    it "takes the last usageMetadata block across streamed chunks" do
      events = [
        { event: nil, data: { "usageMetadata" => { "promptTokenCount" => 80, "candidatesTokenCount" => 5 } } },
        { event: nil, data: { "usageMetadata" => {
          "promptTokenCount" => 80,
          "candidatesTokenCount" => 42,
          "thoughtsTokenCount" => 10,
          "totalTokenCount" => 132
        } } }
      ]

      result = parser.parse_stream(url, nil, 200, events)

      expect(result.provider).to eq("gemini")
      expect(result.model).to eq("gemini-2.5-flash")
      expect(result.input_tokens).to eq(80)
      expect(result.output_tokens).to eq(52)
      expect(result.total_tokens).to eq(132)
      expect(result.stream).to be true
      expect(result.usage_source).to eq(:stream_final)
    end

    it "returns an unknown-usage ParsedUsage when no usage metadata is seen" do
      result = parser.parse_stream(url, nil, 200, [{ event: nil, data: { "text" => "hi" } }])

      expect(result.stream).to be true
      expect(result.usage_source).to eq(:unknown)
      expect(result.model).to eq("gemini-2.5-flash")
    end

    it "returns a nil model when the streaming URL has no model identifier" do
      result = parser.parse_stream(
        "https://generativelanguage.googleapis.com/v1beta/models:streamGenerateContent",
        nil,
        200,
        [{ event: nil, data: { "text" => "hi" } }]
      )

      expect(result.stream).to be true
      expect(result.usage_source).to eq(:unknown)
      expect(result.model).to be_nil
    end
  end
end
