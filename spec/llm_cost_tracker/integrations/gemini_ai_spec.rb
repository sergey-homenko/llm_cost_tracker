# frozen_string_literal: true

require "spec_helper"
require "gemini-ai"

RSpec.describe LlmCostTracker::Integrations::GeminiAi do
  before { configure_sdk_integration(:gemini_ai) }

  let(:client) do
    Gemini.new(
      credentials: {
        service: "generative-language-api",
        api_key: "test-key"
      },
      options: { model: "gemini-2.5-flash" }
    )
  end

  let(:generate_content_url_pattern) do
    %r{https://generativelanguage\.googleapis\.com/v1/models/gemini-2\.5-flash:generateContent}
  end

  let(:request_params) do
    { contents: [{ role: "user", parts: [{ text: "Hello" }] }] }
  end

  describe "generate_content (blocking)" do
    it "records token usage from a real SDK response shape" do
      stub_sdk_json(
        :post, generate_content_url_pattern,
        provider: :gemini, fixture: "generate_content_basic.json"
      )

      capture_sdk_events do |events|
        response = client.generate_content(request_params)

        expect(response).to be_a(Hash)
        expect(events.size).to eq(1)
        expect(events.first).to include(
          provider: "gemini",
          model: "gemini-2.5-flash-preview-05-20",
          input_tokens: 10,
          output_tokens: 9,
          usage_source: "response",
          provider_response_id: "gemini-sdk-resp-001"
        )
      end
    end

    it "does not record when the upstream call raises" do
      WebMock.stub_request(:post, generate_content_url_pattern).to_return(
        status: 429,
        body: { error: { message: "Resource exhausted", code: 429 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        expect { client.generate_content(request_params) }.to raise_error(Faraday::ClientError)
        expect(events).to be_empty
      end
    end
  end

  describe "generate_content (SSE / streaming)" do
    let(:sse_url_pattern) do
      %r{https://generativelanguage\.googleapis\.com/v1/models/gemini-2\.5-flash:generateContent\?alt=sse}
    end

    let(:sse_body) do
      <<~SSE
        data: {"candidates":[{"content":{"parts":[{"text":"Hello"}],"role":"model"},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":10,"candidatesTokenCount":9,"totalTokenCount":19},"responseId":"gemini-stream-001"}

      SSE
    end

    it "records token usage from an SSE streaming call" do
      stub_sdk_sse(:post, sse_url_pattern, body: sse_body)

      capture_sdk_events do |events|
        client.generate_content(request_params, server_sent_events: true) do |_event, _parsed, _raw|
          nil
        end

        expect(events.size).to eq(1)
        expect(events.first).to include(
          provider: "gemini",
          model: "gemini-2.5-flash",
          input_tokens: 10,
          output_tokens: 9
        )
      end
    end

    it "does not record when the upstream SSE call raises" do
      WebMock.stub_request(:post, sse_url_pattern).to_return(
        status: 429,
        body: { error: { message: "Resource exhausted", code: 429 } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      capture_sdk_events do |events|
        expect do
          client.generate_content(request_params, server_sent_events: true) do |_event, _parsed, _raw|
            nil
          end
        end.to raise_error(Faraday::ClientError)
        expect(events).to be_empty
      end
    end
  end
end
