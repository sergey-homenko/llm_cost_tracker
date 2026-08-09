# frozen_string_literal: true

require "spec_helper"
require "uri"

RSpec.describe LlmCostTracker::Providers::Anthropic::Parser do
  subject(:parser) { described_class.new }

  let(:anthropic_messages_url) { URI::HTTPS.build(host: "api.anthropic.com", path: "/v1/messages").to_s }
  let(:openai_chat_url) { URI::HTTPS.build(host: "api.openai.com", path: "/v1/chat/completions").to_s }

  describe "#match?" do
    it_behaves_like "a parser with invalid URL handling"

    it "matches Anthropic messages URL" do
      expect(described_class.match?(anthropic_messages_url)).to be true
    end

    it "does not match OpenAI URLs" do
      expect(described_class.match?(openai_chat_url)).to be false
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
          cache_creation_input_tokens: 30,
          cache_creation: {
            ephemeral_5m_input_tokens: 20,
            ephemeral_1h_input_tokens: 10
          }
        }
      }.to_json
    end

    it_behaves_like "a parser with common usage failure handling",
                    url: URI::HTTPS.build(host: "api.anthropic.com", path: "/v1/messages").to_s,
                    request_body: { model: "claude-sonnet-4-6" }.to_json,
                    response_body: { error: "rate limited" }.to_json,
                    missing_usage_body: { model: "claude-sonnet-4-6" }.to_json

    it "extracts token usage including cache tokens" do
      result = parser.parse(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        response_body: response_body
      )

      expect(result.provider).to eq("anthropic")
      expect(result.model).to eq("claude-sonnet-4-6")
      expect(result.token_usage.input_tokens).to eq(200)
      expect(result.token_usage.output_tokens).to eq(80)
      expect(result.token_usage.total_tokens).to eq(360)
      expect(result.token_usage.cache_read_input_tokens).to eq(50)
      expect(result.token_usage.cache_write_input_tokens).to eq(20)
      expect(result.token_usage.cache_write_extended_input_tokens).to eq(10)
      expect(result.stream).to be false
      expect(result.usage_source).to eq("response")
      expect(result.provider_response_id).to be_nil
    end

    it "records thinking tokens as hidden output without inflating billable output" do
      body = {
        model: "claude-sonnet-4-6",
        usage: {
          input_tokens: 200,
          output_tokens: 80,
          output_tokens_details: { thinking_tokens: 55 }
        }
      }.to_json

      result = parser.parse(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        response_body: body
      )

      expect(result.token_usage.hidden_output_tokens).to eq(55)
      expect(result.token_usage.output_tokens).to eq(80)
      expect(result.token_usage.total_tokens).to eq(280)
    end

    it "reports no hidden output when the response omits thinking token details" do
      result = parser.parse(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        response_body: response_body
      )

      expect(result.token_usage.hidden_output_tokens).to eq(0)
    end

    it "warns when cache creation has an unexpected shape" do
      allow(LlmCostTracker::Logging).to receive(:warn)

      ["unexpected", ["unexpected"]].each do |cache_creation|
        result = parser.parse(
          request_url: anthropic_messages_url,
          request_body: request_body,
          response_status: 200,
          response_body: {
            model: "claude-sonnet-4-6",
            usage: {
              input_tokens: 200,
              output_tokens: 80,
              cache_creation: cache_creation
            }
          }.to_json
        )

        expect(result.token_usage.cache_write_input_tokens).to eq(0)
        expect(result.token_usage.cache_write_extended_input_tokens).to eq(0)
      end

      expect(LlmCostTracker::Logging).to have_received(:warn).with(include("String"))
      expect(LlmCostTracker::Logging).to have_received(:warn).with(include("Array"))
    end

    it "extracts the provider message id from a successful response" do
      result = parser.parse(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        response_body: {
          id: "msg_123",
          model: "claude-sonnet-4-6",
          usage: {
            input_tokens: 200,
            output_tokens: 80
          }
        }.to_json
      )

      expect(result.provider_response_id).to eq("msg_123")
    end

    it "preserves Anthropic Priority Tier as :priority so committed pricing isn't billed at standard rates" do
      result = parser.parse(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        response_body: {
          id: "msg_123",
          model: "claude-sonnet-4-6",
          usage: {
            input_tokens: 200,
            output_tokens: 80,
            service_tier: "priority"
          }
        }.to_json
      )

      expect(result.pricing_mode).to eq("priority")
    end

    it "captures the batch service tier as a pricing mode" do
      result = parser.parse(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        response_body: {
          id: "msg_123",
          model: "claude-sonnet-4-6",
          usage: {
            input_tokens: 200,
            output_tokens: 80,
            service_tier: "batch"
          }
        }.to_json
      )

      expect(result.pricing_mode).to eq("batch")
    end

    it "captures fast US inference as a combined pricing mode" do
      result = parser.parse(
        request_url: anthropic_messages_url,
        request_body: { model: "claude-opus-4-6", speed: "fast", inference_geo: "us" }.to_json,
        response_status: 200,
        response_body: {
          id: "msg_123",
          model: "claude-opus-4-6",
          usage: {
            input_tokens: 200,
            output_tokens: 80,
            inference_geo: "us"
          }
        }.to_json
      )

      expect(result.pricing_mode).to eq("fast_data_residency")
    end

    it "ignores inference_geo values that are not in the documented data-residency uplift list" do
      result = parser.parse(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        response_body: {
          id: "msg_global",
          model: "claude-sonnet-4-6",
          usage: { input_tokens: 200, output_tokens: 80, inference_geo: "global" }
        }.to_json
      )

      expect(result.pricing_mode).to be_nil
    end

    it "extracts provider-reported server tool usage as service charges" do
      result = parser.parse(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        response_body: {
          id: "msg_123",
          model: "claude-sonnet-4-6",
          usage: {
            input_tokens: 200,
            output_tokens: 80,
            server_tool_use: {
              web_search_requests: 2,
              web_fetch_requests: 1
            }
          }
        }.to_json
      )

      service_lines = result.line_items.reject { |item| item.unit == "token" }
      expect(service_lines.map(&:kind)).to eq(%w[web_search_request web_fetch_request])
      expect(service_lines.map(&:quantity).map(&:to_i)).to eq([2, 1])
      expect(service_lines.map(&:cost_status).uniq).to eq([LlmCostTracker::Charges::CostStatus::UNKNOWN])
    end
  end

  describe "#parse_stream" do
    let(:request_body) { { model: "claude-sonnet-4-6", stream: true }.to_json }

    it "carries thinking tokens from the final message_delta into hidden output" do
      events = [
        { event: "message_start", data: {
          "type" => "message_start",
          "message" => {
            "id" => "msg_789",
            "model" => "claude-sonnet-4-6",
            "usage" => { "input_tokens" => 120, "output_tokens" => 1 }
          }
        } },
        { event: "message_delta", data: {
          "type" => "message_delta",
          "usage" => { "output_tokens" => 64, "output_tokens_details" => { "thinking_tokens" => 48 } }
        } }
      ]

      result = parser.parse_stream(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        events: events
      )

      expect(result.token_usage.hidden_output_tokens).to eq(48)
      expect(result.token_usage.output_tokens).to eq(64)
    end

    it "merges message_start usage with message_delta cumulative totals" do
      events = [
        { event: "message_start", data: {
          "type" => "message_start",
          "message" => {
            "id" => "msg_456",
            "model" => "claude-sonnet-4-6",
            "usage" => {
              "input_tokens" => 120,
              "output_tokens" => 1,
              "cache_read_input_tokens" => 40,
              "cache_creation_input_tokens" => 30,
              "cache_creation" => {
                "ephemeral_5m_input_tokens" => 20,
                "ephemeral_1h_input_tokens" => 10
              }
            }
          }
        } },
        { event: "message_delta", data: {
          "type" => "message_delta",
          "usage" => { "output_tokens" => 64 }
        } }
      ]

      result = parser.parse_stream(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        events: events
      )

      expect(result.provider).to eq("anthropic")
      expect(result.model).to eq("claude-sonnet-4-6")
      expect(result.token_usage.input_tokens).to eq(120)
      expect(result.token_usage.output_tokens).to eq(64)
      expect(result.token_usage.total_tokens).to eq(120 + 64 + 40 + 20 + 10)
      expect(result.token_usage.cache_read_input_tokens).to eq(40)
      expect(result.token_usage.cache_write_input_tokens).to eq(20)
      expect(result.token_usage.cache_write_extended_input_tokens).to eq(10)
      expect(result.stream).to be true
      expect(result.usage_source).to eq("stream_final")
      expect(result.provider_response_id).to eq("msg_456")
    end

    it "records unknown usage when message_start is received but message_delta never arrives" do
      events = [
        { event: "message_start", data: {
          "type" => "message_start",
          "message" => {
            "id" => "msg_partial",
            "model" => "claude-sonnet-4-6",
            "usage" => { "input_tokens" => 120, "output_tokens" => 1 }
          }
        } }
      ]

      result = parser.parse_stream(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        events: events
      )

      expect(result.usage_source).to eq("unknown")
      expect(result.token_usage.output_tokens).to eq(0)
    end

    it "preserves Anthropic Priority Tier in stream usage as :priority" do
      events = [
        { event: "message_start", data: {
          "type" => "message_start",
          "message" => {
            "id" => "msg_456",
            "model" => "claude-sonnet-4-6",
            "usage" => {
              "input_tokens" => 120,
              "output_tokens" => 1,
              "service_tier" => "priority"
            }
          }
        } },
        { event: "message_delta", data: {
          "type" => "message_delta",
          "usage" => { "output_tokens" => 64 }
        } }
      ]

      result = parser.parse_stream(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        events: events
      )

      expect(result.pricing_mode).to eq("priority")
    end

    it "captures the batch service tier in stream usage" do
      events = [
        { event: "message_start", data: {
          "type" => "message_start",
          "message" => {
            "id" => "msg_batch",
            "model" => "claude-sonnet-4-6",
            "usage" => {
              "input_tokens" => 120,
              "output_tokens" => 1,
              "service_tier" => "batch"
            }
          }
        } },
        { event: "message_delta", data: {
          "type" => "message_delta",
          "usage" => { "output_tokens" => 64 }
        } }
      ]

      result = parser.parse_stream(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200,
        events: events
      )

      expect(result.pricing_mode).to eq("batch")
    end

    it "combines request speed with stream inference_geo into fast_data_residency" do
      events = [
        { event: "message_start", data: {
          "type" => "message_start",
          "message" => {
            "id" => "msg_456",
            "model" => "claude-opus-4-6",
            "usage" => {
              "input_tokens" => 120,
              "output_tokens" => 1,
              "inference_geo" => "us"
            }
          }
        } },
        { event: "message_delta", data: {
          "type" => "message_delta",
          "usage" => { "output_tokens" => 64 }
        } }
      ]

      result = parser.parse_stream(
        request_url: anthropic_messages_url,
        request_body: { model: "claude-opus-4-6", stream: true, speed: "fast" }.to_json,
        response_status: 200,
        events: events
      )

      expect(result.pricing_mode).to eq("fast_data_residency")
    end

    it "returns unknown usage when no message events are present" do
      result = parser.parse_stream(
        request_url: anthropic_messages_url,
        request_body: request_body,
        response_status: 200
      )

      expect(result.stream).to be true
      expect(result.usage_source).to eq("unknown")
      expect(result.token_usage.input_tokens).to eq(0)
      expect(result.model).to eq("claude-sonnet-4-6")
    end
  end
end
