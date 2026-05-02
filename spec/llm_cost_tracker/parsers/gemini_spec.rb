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

    it "keeps Gemini API thinking tokens out of output token totals" do
      result = parser.parse(
        request_url: generate_content_url,
        request_body: nil,
        response_status: 200,
        response_body: {
          responseId: "gemini-resp-123",
          usageMetadata: {
            promptTokenCount: 100,
            candidatesTokenCount: 25,
            thoughtsTokenCount: 50,
            totalTokenCount: 125
          }
        }.to_json
      )

      expect(result.provider).to eq("gemini")
      expect(result.model).to eq("gemini-2.5-flash")
      expect(result.token_usage.input_tokens).to eq(100)
      expect(result.token_usage.output_tokens).to eq(25)
      expect(result.token_usage.hidden_output_tokens).to eq(50)
      expect(result.token_usage.total_tokens).to eq(125)
      expect(result.stream).to be false
      expect(result.usage_source).to eq(:response)
      expect(result.provider_response_id).to eq("gemini-resp-123")
    end

    it "computes total tokens when Gemini omits totalTokenCount" do
      result = parser.parse(
        request_url: generate_content_url,
        request_body: nil,
        response_status: 200,
        response_body: {
          usageMetadata: {
            promptTokenCount: 100,
            cachedContentTokenCount: 25,
            candidatesTokenCount: 20,
            thoughtsTokenCount: 5
          }
        }.to_json
      )

      expect(result.token_usage.input_tokens).to eq(75)
      expect(result.token_usage.cache_read_input_tokens).to eq(25)
      expect(result.token_usage.output_tokens).to eq(20)
      expect(result.token_usage.total_tokens).to eq(120)
    end

    it "counts tool-use prompt tokens as billable input tokens" do
      result = parser.parse(
        request_url: generate_content_url,
        request_body: nil,
        response_status: 200,
        response_body: {
          usageMetadata: {
            promptTokenCount: 100,
            cachedContentTokenCount: 25,
            toolUsePromptTokenCount: 15,
            candidatesTokenCount: 20,
            thoughtsTokenCount: 5,
            totalTokenCount: 125
          }
        }.to_json
      )

      expect(result.token_usage.input_tokens).to eq(90)
      expect(result.token_usage.cache_read_input_tokens).to eq(25)
      expect(result.token_usage.output_tokens).to eq(20)
      expect(result.token_usage.total_tokens).to eq(135)
    end

    it "captures Flex pricing from the request body" do
      result = parser.parse(
        request_url: generate_content_url,
        request_body: { service_tier: "flex" }.to_json,
        response_status: 200,
        response_body: {
          usageMetadata: {
            promptTokenCount: 100,
            candidatesTokenCount: 20,
            totalTokenCount: 120
          }
        }.to_json
      )

      expect(result.pricing_mode).to eq(:flex)
    end

    it "uses Gemini service tier response headers for Priority pricing" do
      result = parser.parse(
        request_url: generate_content_url,
        request_body: { service_tier: "priority" }.to_json,
        response_status: 200,
        response_body: {
          usageMetadata: {
            promptTokenCount: 100,
            candidatesTokenCount: 20,
            totalTokenCount: 120
          }
        }.to_json,
        response_headers: { "x-gemini-service-tier" => "priority" }
      )

      expect(result.pricing_mode).to eq(:priority)
    end

    it "does not assume Priority pricing when Gemini reports a standard-tier downgrade" do
      result = parser.parse(
        request_url: generate_content_url,
        request_body: { service_tier: "priority" }.to_json,
        response_status: 200,
        response_body: {
          usageMetadata: {
            promptTokenCount: 100,
            candidatesTokenCount: 20,
            totalTokenCount: 120
          }
        }.to_json,
        response_headers: { "x-gemini-service-tier" => "standard" }
      )

      expect(result.pricing_mode).to be_nil
    end

    it "captures Google Search grounding queries as unknown-cost service charges" do
      result = parser.parse(
        request_url: generate_content_url,
        request_body: nil,
        response_status: 200,
        response_body: {
          candidates: [
            { groundingMetadata: { webSearchQueries: ["weather kyiv", "kyiv forecast"] } }
          ],
          usageMetadata: {
            promptTokenCount: 100,
            candidatesTokenCount: 20,
            totalTokenCount: 120
          }
        }.to_json
      )

      expect(result.service_charges.size).to eq(1)
      expect(result.service_charges.first.component).to eq(:grounding_request)
      expect(result.service_charges.first.quantity).to eq(2)
      expect(result.service_charges.first.cost_status).to eq(LlmCostTracker::Billing::CostStatus::UNKNOWN)
      expect(result.service_charges.first.pricing_basis).to eq(
        LlmCostTracker::Billing::ServiceCharge::PROVIDER_USAGE_BASIS
      )
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
            "totalTokenCount" => 122
          }
        } }
      ]

      result = parser.parse_stream(
        request_url: url,
        response_status: 200,
        events: events
      )

      expect(result.provider).to eq("gemini")
      expect(result.model).to eq("gemini-2.5-flash")
      expect(result.token_usage.input_tokens).to eq(80)
      expect(result.token_usage.output_tokens).to eq(42)
      expect(result.token_usage.hidden_output_tokens).to eq(10)
      expect(result.token_usage.total_tokens).to eq(122)
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

      result = parser.parse_stream(
        request_url: url,
        response_status: 200,
        events: events
      )

      expect(result.token_usage.input_tokens).to eq(70)
      expect(result.token_usage.cache_read_input_tokens).to eq(10)
      expect(result.token_usage.output_tokens).to eq(42)
      expect(result.token_usage.total_tokens).to eq(122)
    end

    it "captures streamed Google Search grounding queries from the latest grounded candidate" do
      events = [
        { event: nil, data: {
          "candidates" => [
            { "groundingMetadata" => { "webSearchQueries" => ["first query"] } }
          ]
        } },
        { event: nil, data: {
          "candidates" => [
            { "groundingMetadata" => { "webSearchQueries" => ["latest one", "latest two"] } }
          ],
          "usageMetadata" => {
            "promptTokenCount" => 80,
            "candidatesTokenCount" => 42,
            "totalTokenCount" => 122
          }
        } }
      ]

      result = parser.parse_stream(
        request_url: url,
        response_status: 200,
        events: events
      )

      expect(result.service_charges.size).to eq(1)
      expect(result.service_charges.first.component).to eq(:grounding_request)
      expect(result.service_charges.first.quantity).to eq(2)
    end

    it "returns an unknown-usage UsageCapture when no usage metadata is seen" do
      result = parser.parse_stream(
        request_url: url,
        response_status: 200,
        events: [{ event: nil, data: { "text" => "hi", "responseId" => "gemini-resp-789" } }]
      )

      expect(result.stream).to be true
      expect(result.usage_source).to eq(:unknown)
      expect(result.model).to eq("gemini-2.5-flash")
      expect(result.provider_response_id).to eq("gemini-resp-789")
    end

    it "captures stream pricing modes from Gemini service tier headers" do
      result = parser.parse_stream(
        request_url: url,
        request_body: { service_tier: "priority" }.to_json,
        response_status: 200,
        events: [
          { event: nil, data: {
            "usageMetadata" => {
              "promptTokenCount" => 80,
              "candidatesTokenCount" => 42,
              "totalTokenCount" => 122
            }
          } }
        ],
        response_headers: { "X-Gemini-Service-Tier" => "priority" }
      )

      expect(result.pricing_mode).to eq(:priority)
    end

    it "returns unknown when the streaming URL has no model identifier" do
      result = parser.parse_stream(
        request_url: model_less_stream_url,
        response_status: 200,
        events: [{ event: nil, data: { "text" => "hi" } }]
      )

      expect(result.stream).to be true
      expect(result.usage_source).to eq(:unknown)
      expect(result.model).to eq("unknown")
    end
  end
end
