# frozen_string_literal: true

require "spec_helper"
require "anthropic"

RSpec.describe LlmCostTracker::Integrations::Anthropic do
  before { configure_sdk_integration(:anthropic) }

  let(:client) { Anthropic::Client.new(api_key: "test-key") }
  let(:request_params) do
    { model: "claude-sonnet-4-5-20250929", max_tokens: 100, messages: [{ role: "user", content: "hi" }] }
  end

  describe "messages.create" do
    it "records token usage with cache TTL split from a real SDK response" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_with_cache.json")

      capture_sdk_events do |events|
        response = client.messages.create(**request_params)

        expect(response).to be_a(Anthropic::Models::Message)
        expect(events.first).to include(
          provider: "anthropic",
          model: "claude-sonnet-4-5-20250929",
          input_tokens: 120,
          output_tokens: 35,
          cache_read_input_tokens: 50,
          cache_write_input_tokens: 20,
          cache_write_extended_input_tokens: 10,
          usage_source: "sdk_response",
          provider_response_id: "msg_123"
        )
      end
    end

    it "treats priority service tier as standard pricing (throughput, not per-token uplift)" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_priority_tier.json")

      capture_sdk_events do |events|
        client.messages.create(**request_params)
        expect(events.first[:pricing_mode]).to be_nil
      end
    end

    it "captures the batch service tier as a pricing mode" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_batch_tier.json")

      capture_sdk_events do |events|
        client.messages.create(**request_params)
        expect(events.first[:pricing_mode]).to eq(:batch)
      end
    end

    it "combines fast mode and US inference into fast_data_residency" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_fast_data_residency.json")

      capture_sdk_events do |events|
        client.messages.create(model: "claude-opus-4-6", max_tokens: 100,
                               messages: [{ role: "user", content: "hi" }],
                               speed: "fast", inference_geo: "us")
        expect(events.first[:pricing_mode]).to eq(:fast_data_residency)
      end
    end

    it "records server tool usage as service line items" do
      stub_sdk_json(:post, "https://api.anthropic.com/v1/messages",
                    provider: :anthropic, fixture: "messages_with_server_tools.json")

      capture_sdk_events do |events|
        client.messages.create(**request_params)

        service_lines = events.first[:line_items].reject { |item| item[:unit] == "token" }
        expect(service_lines.map { |item| item[:kind] }).to contain_exactly("web_search_request")
        expect(service_lines.map { |item| item[:quantity].to_i }).to contain_exactly(2)
      end
    end
  end

  describe "messages.stream / stream_raw" do
    let(:sse_body) do
      <<~SSE
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_stream_1","model":"claude-sonnet-4-5-20250929","usage":{"input_tokens":120,"output_tokens":1}}}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":64}}

        event: message_stop
        data: {"type":"message_stop"}

      SSE
    end

    it "records token usage from a real SDK stream" do
      stub_sdk_sse(:post, "https://api.anthropic.com/v1/messages", body: sse_body)

      capture_sdk_events do |events|
        stream = client.messages.stream(**request_params)
        stream.each { |_| }

        expect(events.first).to include(
          provider: "anthropic",
          model: "claude-sonnet-4-5-20250929",
          input_tokens: 120,
          output_tokens: 64,
          stream: true,
          usage_source: "stream_final",
          provider_response_id: "msg_stream_1"
        )
      end
    end

    it "records token usage from stream_raw" do
      stub_sdk_sse(:post, "https://api.anthropic.com/v1/messages", body: sse_body)

      capture_sdk_events do |events|
        stream = client.messages.stream_raw(**request_params)
        stream.each { |_| }

        expect(events.first).to include(
          provider: "anthropic",
          input_tokens: 120,
          output_tokens: 64,
          stream: true,
          provider_response_id: "msg_stream_1"
        )
      end
    end
  end
end
