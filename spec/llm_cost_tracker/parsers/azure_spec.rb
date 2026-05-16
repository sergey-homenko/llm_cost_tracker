# frozen_string_literal: true

require "spec_helper"
require "uri"

RSpec.describe LlmCostTracker::Parsers::Azure do
  subject(:parser) { described_class.new }

  let(:chat_completions_url) do
    URI::HTTPS.build(
      host: "myresource.openai.azure.com",
      path: "/openai/deployments/gpt4o-prod/chat/completions",
      query: "api-version=2024-10-21"
    ).to_s
  end

  let(:embeddings_url) do
    URI::HTTPS.build(
      host: "tenant.openai.azure.com",
      path: "/openai/deployments/embed-3-large/embeddings",
      query: "api-version=2024-10-21"
    ).to_s
  end

  let(:audio_translations_url) do
    URI::HTTPS.build(
      host: "tenant.openai.azure.com",
      path: "/openai/deployments/whisper-1/audio/translations"
    ).to_s
  end

  let(:images_url) do
    URI::HTTPS.build(
      host: "tenant.openai.azure.com",
      path: "/openai/deployments/dalle-3/images/generations"
    ).to_s
  end

  let(:openai_direct_url) { URI::HTTPS.build(host: "api.openai.com", path: "/v1/chat/completions").to_s }

  describe "#match?" do
    it_behaves_like "a parser with invalid URL handling"

    it "matches Azure OpenAI chat completions" do
      expect(described_class.match?(chat_completions_url)).to be true
    end

    it "matches Azure OpenAI embeddings" do
      expect(described_class.match?(embeddings_url)).to be true
    end

    it "matches Azure OpenAI audio translations and images endpoints" do
      expect(described_class.match?(audio_translations_url)).to be true
      expect(described_class.match?(images_url)).to be true
    end

    it "matches the remaining classic Azure OpenAI endpoints" do
      %w[audio/speech images/edits images/variations moderations].each do |endpoint|
        url = URI::HTTPS.build(
          host: "myresource.openai.azure.com",
          path: "/openai/deployments/deploy-1/#{endpoint}"
        ).to_s
        expect(described_class.match?(url)).to be(true), "expected match? to be true for #{endpoint}"
      end
    end

    it "does not match Azure resource management or other Azure surfaces" do
      mgmt = URI::HTTPS.build(host: "management.azure.com", path: "/subscriptions/abc").to_s
      cog = URI::HTTPS.build(host: "myresource.cognitiveservices.azure.com",
                             path: "/openai/deployments/gpt4o/chat/completions").to_s
      expect(described_class.match?(mgmt)).to be false
      expect(described_class.match?(cog)).to be false
    end

    it "does not match OpenAI direct URLs (the Openai parser owns those)" do
      expect(described_class.match?(openai_direct_url)).to be false
    end

    it "does not match paths that omit the deployment segment" do
      bare = URI::HTTPS.build(host: "myresource.openai.azure.com", path: "/openai/chat/completions").to_s
      expect(described_class.match?(bare)).to be false
    end
  end

  describe "#model_for" do
    it "returns the request body's model when present" do
      expect(parser.model_for(chat_completions_url, { "model" => "gpt-4o" })).to eq("gpt-4o")
    end

    it "falls back to the deployment-id from the URL path when the body has no model" do
      expect(parser.model_for(chat_completions_url, {})).to eq("gpt4o-prod")
      expect(parser.model_for(embeddings_url, nil)).to eq("embed-3-large")
    end

    it "returns nil when neither the body nor the URL carry a deployment" do
      bogus = URI::HTTPS.build(host: "myresource.openai.azure.com", path: "/openai/chat/completions").to_s
      expect(parser.model_for(bogus, {})).to be_nil
    end
  end

  describe "#parse" do
    it "extracts token usage from a successful Azure response and tags provider as azure_openai" do
      result = parser.parse(
        request_url: chat_completions_url,
        request_body: { messages: [] }.to_json,
        response_status: 200,
        response_body: {
          id: "chatcmpl_az_123",
          model: "gpt-4o-2024-08-06",
          usage: { prompt_tokens: 100, completion_tokens: 25, total_tokens: 125 }
        }.to_json
      )

      expect(result.provider).to eq("azure_openai")
      expect(result.model).to eq("gpt-4o-2024-08-06")
      expect(result.token_usage.input_tokens).to eq(100)
      expect(result.token_usage.output_tokens).to eq(25)
      expect(result.token_usage.total_tokens).to eq(125)
      expect(result.provider_response_id).to eq("chatcmpl_az_123")
    end

    it "returns nil on non-200" do
      result = parser.parse(
        request_url: chat_completions_url,
        request_body: "{}",
        response_status: 429,
        response_body: { error: "throttled" }.to_json
      )

      expect(result).to be_nil
    end
  end

  describe "#parse_stream" do
    it "extracts usage from final stream chunks" do
      events = [
        { event: nil, data: { "id" => "chatcmpl_az_stream", "model" => "gpt-4o" } },
        { event: nil, data: { "usage" => { "prompt_tokens" => 12, "completion_tokens" => 4, "total_tokens" => 16 } } }
      ]

      result = parser.parse_stream(
        request_url: chat_completions_url,
        request_body: { stream: true }.to_json,
        response_status: 200,
        events: events
      )

      expect(result.provider).to eq("azure_openai")
      expect(result.token_usage.input_tokens).to eq(12)
      expect(result.token_usage.output_tokens).to eq(4)
      expect(result.usage_source).to eq(:stream_final)
    end
  end

  describe "#auto_enable_stream_usage?" do
    it "opts in for chat completions paths" do
      expect(parser.auto_enable_stream_usage?(chat_completions_url)).to be true
    end

    it "leaves embeddings alone" do
      expect(parser.auto_enable_stream_usage?(embeddings_url)).to be false
    end
  end
end
