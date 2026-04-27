# frozen_string_literal: true

require "spec_helper"
require "uri"

RSpec.describe LlmCostTracker::Parsers::Gemini do
  subject(:parser) { described_class.new }

  let(:generate_content_url) do
    URI::HTTPS.build(
      host: "generativelanguage.googleapis.com",
      path: "/v1beta/models/gemini-2.5-flash:generateContent"
    ).to_s
  end
  let(:stream_generate_content_url) do
    URI::HTTPS.build(
      host: "generativelanguage.googleapis.com",
      path: "/v1beta/models/gemini-2.5-flash:streamGenerateContent"
    ).to_s
  end
  let(:models_index_url) do
    URI::HTTPS.build(host: "generativelanguage.googleapis.com", path: "/v1beta/models").to_s
  end
  let(:model_less_stream_url) do
    URI::HTTPS.build(host: "generativelanguage.googleapis.com", path: "/v1beta/models:streamGenerateContent").to_s
  end

  describe "#match?" do
    it_behaves_like "a parser with invalid URL handling"

    it "matches Gemini URLs case-insensitively" do
      uppercased_host_url = URI::HTTPS.build(
        host: "GENERATIVELANGUAGE.googleapis.com",
        path: "/v1beta/models/gemini-2.5-flash:generateContent"
      ).to_s

      expect(parser.match?(uppercased_host_url)).to be true
    end

    it "matches Gemini streaming generation URLs" do
      expect(parser.match?(stream_generate_content_url)).to be true
    end

    it "does not match unrelated Gemini endpoints" do
      expect(parser.match?(models_index_url)).to be false
    end
  end

  describe "#parse" do
    it_behaves_like "a parser with common usage failure handling",
                    url: URI::HTTPS.build(
                      host: "generativelanguage.googleapis.com",
                      path: "/v1beta/models/gemini-2.5-flash:generateContent"
                    ).to_s,
                    request_body: nil,
                    response_body: { error: "rate limited" }.to_json,
                    missing_usage_body: { model: "gemini-2.5-flash" }.to_json

    it "counts thinking tokens as output tokens" do
      result = parser.parse(
        generate_content_url,
        nil,
        200,
        {
          responseId: "gemini-resp-123",
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
      expect(result.hidden_output_tokens).to eq(50)
      expect(result.total_tokens).to eq(175)
      expect(result.stream).to be false
      expect(result.usage_source).to eq(:response)
      expect(result.provider_response_id).to eq("gemini-resp-123")
    end

    it "computes total tokens when Gemini omits totalTokenCount" do
      result = parser.parse(
        generate_content_url,
        nil,
        200,
        {
          usageMetadata: {
            promptTokenCount: 100,
            cachedContentTokenCount: 25,
            candidatesTokenCount: 20,
            thoughtsTokenCount: 5
          }
        }.to_json
      )

      expect(result.input_tokens).to eq(75)
      expect(result.cache_read_input_tokens).to eq(25)
      expect(result.output_tokens).to eq(25)
      expect(result.total_tokens).to eq(125)
    end
  end

  describe "#streaming_request?" do
    it "flags the streamGenerateContent path as streaming" do
      expect(parser.streaming_request?(
               stream_generate_content_url,
               nil
             )).to be true
    end

    it "does not flag generateContent as streaming" do
      expect(parser.streaming_request?(
               generate_content_url,
               nil
             )).to be false
    end
  end

  describe "#parse_stream" do
    let(:url) { stream_generate_content_url }

    it "takes the last usageMetadata block across streamed chunks" do
      events = [
        { event: nil, data: { "usageMetadata" => { "promptTokenCount" => 80, "candidatesTokenCount" => 5 } } },
        { event: nil, data: {
          "responseId" => "gemini-resp-456",
          "usageMetadata" => {
            "promptTokenCount" => 80,
            "candidatesTokenCount" => 42,
            "thoughtsTokenCount" => 10,
            "totalTokenCount" => 132
          }
        } }
      ]

      result = parser.parse_stream(url, nil, 200, events)

      expect(result.provider).to eq("gemini")
      expect(result.model).to eq("gemini-2.5-flash")
      expect(result.input_tokens).to eq(80)
      expect(result.output_tokens).to eq(52)
      expect(result.hidden_output_tokens).to eq(10)
      expect(result.total_tokens).to eq(132)
      expect(result.stream).to be true
      expect(result.usage_source).to eq(:stream_final)
      expect(result.provider_response_id).to eq("gemini-resp-456")
    end

    it "computes stream total tokens when Gemini omits totalTokenCount" do
      events = [
        { event: nil, data: {
          "usageMetadata" => {
            "promptTokenCount" => 80,
            "cachedContentTokenCount" => 10,
            "candidatesTokenCount" => 42,
            "thoughtsTokenCount" => 8
          }
        } }
      ]

      result = parser.parse_stream(url, nil, 200, events)

      expect(result.input_tokens).to eq(70)
      expect(result.cache_read_input_tokens).to eq(10)
      expect(result.output_tokens).to eq(50)
      expect(result.total_tokens).to eq(130)
    end

    it "returns an unknown-usage ParsedUsage when no usage metadata is seen" do
      result = parser.parse_stream(
        url,
        nil,
        200,
        [{ event: nil, data: { "text" => "hi", "responseId" => "gemini-resp-789" } }]
      )

      expect(result.stream).to be true
      expect(result.usage_source).to eq(:unknown)
      expect(result.model).to eq("gemini-2.5-flash")
      expect(result.provider_response_id).to eq("gemini-resp-789")
    end

    it "returns unknown when the streaming URL has no model identifier" do
      result = parser.parse_stream(
        model_less_stream_url,
        nil,
        200,
        [{ event: nil, data: { "text" => "hi" } }]
      )

      expect(result.stream).to be true
      expect(result.usage_source).to eq(:unknown)
      expect(result.model).to eq("unknown")
    end
  end
end
