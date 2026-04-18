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

      expect(result[:provider]).to eq("gemini")
      expect(result[:model]).to eq("gemini-2.5-flash")
      expect(result[:input_tokens]).to eq(100)
      expect(result[:output_tokens]).to eq(75)
      expect(result[:total_tokens]).to eq(175)
    end
  end
end
