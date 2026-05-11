# frozen_string_literal: true

require "spec_helper"
require "uri"

RSpec.describe LlmCostTracker::Parsers::Openai do
  subject(:parser) { described_class.new }

  let(:chat_completions_url) { URI::HTTPS.build(host: "api.openai.com", path: "/v1/chat/completions").to_s }
  let(:embeddings_url) { URI::HTTPS.build(host: "api.openai.com", path: "/v1/embeddings").to_s }
  let(:responses_url) { URI::HTTPS.build(host: "api.openai.com", path: "/v1/responses").to_s }
  let(:regional_responses_url) { URI::HTTPS.build(host: "us.api.openai.com", path: "/v1/responses").to_s }
  let(:response_retrieval_url) { URI::HTTPS.build(host: "api.openai.com", path: "/v1/responses/resp_123").to_s }
  let(:anthropic_messages_url) { URI::HTTPS.build(host: "api.anthropic.com", path: "/v1/messages").to_s }

  describe "#match?" do
    it_behaves_like "a parser with invalid URL handling"

    it "matches OpenAI chat completions URL" do
      expect(parser.match?(chat_completions_url)).to be true
    end

    it "matches OpenAI embeddings URL" do
      expect(parser.match?(embeddings_url)).to be true
    end

    it "matches OpenAI Responses URL" do
      expect(parser.match?(responses_url)).to be true
    end

    it "matches OpenAI regional processing URLs" do
      expect(parser.match?(regional_responses_url)).to be true
    end

    it "does not match OpenAI response retrieval URLs" do
      expect(parser.match?(response_retrieval_url)).to be false
    end

    it "does not match other URLs" do
      expect(parser.match?(anthropic_messages_url)).to be false
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

    it_behaves_like "a parser with common usage failure handling",
                    url: URI::HTTPS.build(host: "api.openai.com", path: "/v1/chat/completions").to_s,
                    request_body: { model: "gpt-4o" }.to_json,
                    response_body: { error: "rate limited" }.to_json,
                    missing_usage_body: { model: "gpt-4o" }.to_json

    it "extracts token usage from a successful response" do
      result = parser.parse(
        request_url: chat_completions_url,
        request_body: request_body,
        response_status: 200,
        response_body: {
          id: "chatcmpl_123",
          model: "gpt-4o",
          usage: {
            prompt_tokens: 150,
            completion_tokens: 42,
            total_tokens: 192
          }
        }.to_json
      )

      expect(result).to be_a(LlmCostTracker::UsageCapture)
      expect(result.provider).to eq("openai")
      expect(result.model).to eq("gpt-4o")
      expect(result.token_usage.input_tokens).to eq(150)
      expect(result.token_usage.output_tokens).to eq(42)
      expect(result.provider_response_id).to eq("chatcmpl_123")
    end

    it "captures non-standard service tiers as pricing modes" do
      result = parser.parse(
        request_url: chat_completions_url,
        request_body: request_body,
        response_status: 200,
        response_body: {
          model: "gpt-4o",
          service_tier: "priority",
          usage: {
            prompt_tokens: 150,
            completion_tokens: 42,
            total_tokens: 192
          }
        }.to_json
      )

      expect(result.pricing_mode).to eq(:priority)
    end

    it "captures OpenAI regional processing for eligible models" do
      result = parser.parse(
        request_url: regional_responses_url,
        request_body: { model: "gpt-5.5", service_tier: "priority" }.to_json,
        response_status: 200,
        response_body: {
          model: "gpt-5.5",
          usage: {
            input_tokens: 150,
            output_tokens: 42,
            total_tokens: 192
          }
        }.to_json
      )

      expect(result.pricing_mode).to eq(:priority_data_residency)
    end

    it "does not mark non-uplift OpenAI regional models as data residency pricing" do
      result = parser.parse(
        request_url: regional_responses_url,
        request_body: { model: "gpt-5.2" }.to_json,
        response_status: 200,
        response_body: {
          model: "gpt-5.2",
          usage: {
            input_tokens: 150,
            output_tokens: 42,
            total_tokens: 192
          }
        }.to_json
      )

      expect(result.pricing_mode).to be_nil
    end

    it "treats non-US/EU regional OpenAI hosts as data residency too" do
      result = parser.parse(
        request_url: URI::HTTPS.build(host: "au.api.openai.com", path: "/v1/responses").to_s,
        request_body: { model: "gpt-5.5", service_tier: "priority" }.to_json,
        response_status: 200,
        response_body: {
          model: "gpt-5.5",
          usage: { input_tokens: 100, output_tokens: 25, total_tokens: 125 }
        }.to_json
      )

      expect(result.pricing_mode).to eq(:priority_data_residency)
    end

    it "ignores data residency mode when the request url cannot be parsed" do
      result = parser.parse(
        request_url: "https://[bad-host]/v1/responses",
        request_body: { model: "gpt-5.5" }.to_json,
        response_status: 200,
        response_body: {
          model: "gpt-5.5",
          usage: { input_tokens: 10, output_tokens: 5, total_tokens: 15 }
        }.to_json
      )

      expect(result.pricing_mode).to be_nil
    end

    it "extracts token usage from a Responses API response" do
      response_body = {
        id: "resp_123",
        model: "gpt-5-mini",
        usage: {
          input_tokens: 150,
          input_tokens_details: { cached_tokens: 100 },
          output_tokens: 42,
          output_tokens_details: { reasoning_tokens: 20 },
          total_tokens: 192
        }
      }.to_json

      result = parser.parse(
        request_url: responses_url,
        request_body: { model: "gpt-5-mini" }.to_json,
        response_status: 200,
        response_body: response_body
      )

      expect(result.provider).to eq("openai")
      expect(result.model).to eq("gpt-5-mini")
      expect(result.token_usage.input_tokens).to eq(50)
      expect(result.token_usage.output_tokens).to eq(42)
      expect(result.token_usage.cache_read_input_tokens).to eq(100)
      expect(result.token_usage.hidden_output_tokens).to eq(20)
      expect(result.provider_response_id).to eq("resp_123")
    end

    it "extracts audio token details from OpenAI usage" do
      response_body = {
        model: "gpt-realtime-1.5",
        usage: {
          input_tokens: 180,
          input_tokens_details: { cached_tokens: 30, audio_tokens: 50 },
          output_tokens: 70,
          output_tokens_details: { audio_tokens: 20, reasoning_tokens: 10 },
          total_tokens: 250
        }
      }.to_json

      result = parser.parse(
        request_url: responses_url,
        request_body: { model: "gpt-realtime-1.5" }.to_json,
        response_status: 200,
        response_body: response_body
      )

      expect(result.token_usage.input_tokens).to eq(100)
      expect(result.token_usage.cache_read_input_tokens).to eq(30)
      expect(result.token_usage.audio_input_tokens).to eq(50)
      expect(result.token_usage.output_tokens).to eq(50)
      expect(result.token_usage.audio_output_tokens).to eq(20)
      expect(result.token_usage.hidden_output_tokens).to eq(10)
      expect(result.token_usage.total_tokens).to eq(250)
    end

    it "captures Responses API hosted tool output items as unknown-cost service charges" do
      response_body = {
        id: "resp_123",
        model: "gpt-5-mini",
        output: [
          {
            type: "web_search_call",
            id: "ws_123",
            status: "completed",
            action: { type: "search" }
          },
          {
            type: "file_search_call",
            id: "fs_123",
            status: "completed"
          },
          {
            type: "code_interpreter_call",
            id: "ci_123",
            status: "completed",
            container_id: "cntr_123"
          },
          {
            type: "code_interpreter_call",
            id: "ci_124",
            status: "completed",
            container_id: "cntr_123"
          }
        ],
        usage: {
          input_tokens: 150,
          output_tokens: 42,
          total_tokens: 192
        }
      }.to_json

      result = parser.parse(
        request_url: responses_url,
        request_body: { model: "gpt-5-mini" }.to_json,
        response_status: 200,
        response_body: response_body
      )

      service_lines = result.line_items.reject { |item| item.unit == :token }
      expect(service_lines.map(&:kind)).to eq(
        %i[web_search_request file_search_call container_session]
      )
      expect(service_lines.map(&:cost_status)).to all(
        eq(LlmCostTracker::Billing::CostStatus::UNKNOWN)
      )
      expect(service_lines.map(&:pricing_basis)).to all(eq(:provider_usage))
      expect(service_lines.map(&:provider_item_id)).to eq(%w[ws_123 fs_123 cntr_123])
      expect(service_lines.first.details).to include("action_type" => "search", "status" => "completed")
      expect(service_lines.last.details).to include("container_id" => "cntr_123")
    end

    it "ignores non-billable OpenAI web search page actions" do
      response_body = {
        id: "resp_123",
        model: "gpt-5-mini",
        output: [
          {
            type: "web_search_call",
            id: "ws_123",
            status: "completed",
            action: { type: "search" }
          },
          {
            type: "web_search_call",
            id: "ws_124",
            status: "completed",
            action: { type: "open_page" }
          },
          {
            type: "web_search_call",
            id: "ws_125",
            status: "completed",
            action: { type: "find_in_page" }
          },
          {
            type: "web_search_call",
            id: "ws_126",
            status: "completed"
          },
          {
            type: "message",
            id: "msg_123",
            status: "completed"
          }
        ],
        usage: {
          input_tokens: 150,
          output_tokens: 42,
          total_tokens: 192
        }
      }.to_json

      result = parser.parse(
        request_url: responses_url,
        request_body: { model: "gpt-5-mini" }.to_json,
        response_status: 200,
        response_body: response_body
      )

      service_lines = result.line_items.reject { |item| item.unit == :token }
      expect(service_lines.map(&:kind)).to eq(%i[web_search_request web_search_request])
      expect(service_lines.map(&:provider_item_id)).to eq(%w[ws_123 ws_126])
    end

    it "tags non-streaming usage with a :response source" do
      result = parser.parse(
        request_url: chat_completions_url,
        request_body: request_body,
        response_status: 200,
        response_body: response_body
      )

      expect(result.stream).to be false
      expect(result.usage_source).to eq(:response)
    end

    it "computes total tokens when the provider omits total_tokens" do
      result = parser.parse(
        request_url: responses_url,
        request_body: { model: "gpt-5-mini" }.to_json,
        response_status: 200,
        response_body: {
          model: "gpt-5-mini",
          usage: {
            input_tokens: 150,
            input_tokens_details: { cached_tokens: 100 },
            output_tokens: 42
          }
        }.to_json
      )

      expect(result.token_usage.input_tokens).to eq(50)
      expect(result.token_usage.cache_read_input_tokens).to eq(100)
      expect(result.token_usage.output_tokens).to eq(42)
      expect(result.token_usage.total_tokens).to eq(192)
    end

    it "uses unknown when neither response nor request carries a model" do
      result = parser.parse(
        request_url: chat_completions_url,
        request_body: {}.to_json,
        response_status: 200,
        response_body: {
          usage: {
            prompt_tokens: 150,
            completion_tokens: 42,
            total_tokens: 192
          }
        }.to_json
      )

      expect(result.model).to eq("unknown")
    end
  end

  describe "#streaming_request?" do
    it "detects a stream:true body" do
      expect(parser.streaming_request?(chat_completions_url,
                                       '{"model":"gpt-4o","stream":true}')).to be true
    end

    it "ignores non-streaming bodies" do
      expect(parser.streaming_request?(chat_completions_url,
                                       '{"model":"gpt-4o"}')).to be false
    end

    it "ignores stream text inside string content" do
      expect(parser.streaming_request?(
               chat_completions_url,
               '{"model":"gpt-4o","messages":[{"role":"user","content":"\\"stream\\":true"}]}'
             )).to be false
    end
  end

  describe "#parse_stream" do
    let(:request_body) { { model: "gpt-4o", stream: true }.to_json }

    it "extracts usage from a final chunk carrying the usage hash" do
      events = [
        { event: nil, data: { "model" => "gpt-4o", "choices" => [{ "delta" => { "content" => "hi" } }] } },
        { event: nil, data: { "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } } }
      ]

      result = parser.parse_stream(
        request_url: chat_completions_url,
        request_body: request_body,
        response_status: 200,
        events: events
      )

      expect(result.provider).to eq("openai")
      expect(result.model).to eq("gpt-4o")
      expect(result.token_usage.input_tokens).to eq(12)
      expect(result.token_usage.output_tokens).to eq(3)
      expect(result.token_usage.total_tokens).to eq(15)
      expect(result.stream).to be true
      expect(result.usage_source).to eq(:stream_final)
      expect(result.provider_response_id).to be_nil
    end

    it "splits image_tokens out of regular text input/output when streamed" do
      events = [
        { event: nil, data: { "model" => "gpt-image-1.5" } },
        { event: nil, data: { "usage" => {
          "prompt_tokens" => 150, "completion_tokens" => 1100,
          "input_tokens_details" => { "image_tokens" => 100 },
          "output_tokens_details" => { "image_tokens" => 1000, "text_tokens" => 100 }
        } } }
      ]

      result = parser.parse_stream(
        request_url: chat_completions_url,
        request_body: { model: "gpt-image-1.5", stream: true }.to_json,
        response_status: 200,
        events: events
      )

      expect(result.token_usage.input_tokens).to eq(50)
      expect(result.token_usage.image_input_tokens).to eq(100)
      expect(result.token_usage.output_tokens).to eq(100)
      expect(result.token_usage.image_output_tokens).to eq(1000)
    end

    it "leaves stream output tokens unsplit when no image/text details arrive" do
      events = [
        { event: nil, data: { "model" => "gpt-4o" } },
        { event: nil, data: { "usage" => { "prompt_tokens" => 10, "completion_tokens" => 20, "total_tokens" => 30 } } }
      ]

      result = parser.parse_stream(
        request_url: chat_completions_url,
        request_body: { model: "gpt-4o", stream: true }.to_json,
        response_status: 200,
        events: events
      )

      expect(result.token_usage.image_input_tokens).to eq(0)
      expect(result.token_usage.image_output_tokens).to eq(0)
      expect(result.token_usage.output_tokens).to eq(20)
    end

    it "extracts usage from SDK chat-completion stream events wrapped in a chunk envelope" do
      events = [
        { event: nil, data: { "chunk" => { "id" => "chatcmpl_chunk", "model" => "gpt-4o" } } },
        { event: nil, data: { "chunk" => { "usage" => { "prompt_tokens" => 8, "completion_tokens" => 2,
                                                        "total_tokens" => 10 } } } }
      ]

      result = parser.parse_stream(
        request_url: chat_completions_url,
        request_body: request_body,
        response_status: 200,
        events: events
      )

      expect(result.token_usage.input_tokens).to eq(8)
      expect(result.token_usage.output_tokens).to eq(2)
      expect(result.model).to eq("gpt-4o")
      expect(result.provider_response_id).to eq("chatcmpl_chunk")
      expect(result.usage_source).to eq(:stream_final)
    end

    it "extracts response ids from chat completion stream chunks" do
      events = [
        {
          event: nil,
          data: { "id" => "chatcmpl_456", "model" => "gpt-4o", "choices" => [{ "delta" => { "content" => "hi" } }] }
        },
        { event: nil, data: { "usage" => { "prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15 } } }
      ]

      result = parser.parse_stream(
        request_url: chat_completions_url,
        request_body: request_body,
        response_status: 200,
        events: events
      )

      expect(result.provider_response_id).to eq("chatcmpl_456")
    end

    it "extracts response ids from Responses API stream events" do
      events = [
        {
          event: nil,
          data: { "type" => "response.created", "response" => { "id" => "resp_456", "model" => "gpt-5-mini" } }
        },
        { event: nil, data: { "usage" => { "input_tokens" => 12, "output_tokens" => 3, "total_tokens" => 15 } } }
      ]

      result = parser.parse_stream(
        request_url: responses_url,
        request_body: { model: "gpt-5-mini", stream: true }.to_json,
        response_status: 200,
        events: events
      )

      expect(result.provider_response_id).to eq("resp_456")
    end

    it "captures service tiers from Responses API stream events" do
      events = [
        {
          event: nil,
          data: {
            "type" => "response.completed",
            "response" => {
              "id" => "resp_456",
              "model" => "gpt-5-mini",
              "service_tier" => "priority",
              "usage" => {
                "input_tokens" => 12,
                "output_tokens" => 3,
                "total_tokens" => 15
              }
            }
          }
        }
      ]

      result = parser.parse_stream(
        request_url: responses_url,
        request_body: { model: "gpt-5-mini", stream: true }.to_json,
        response_status: 200,
        events: events
      )

      expect(result.pricing_mode).to eq(:priority)
    end

    it "extracts usage from Responses API completed events" do
      events = [
        {
          event: nil,
          data: { "type" => "response.created", "response" => { "id" => "resp_456", "model" => "gpt-5-mini" } }
        },
        {
          event: nil,
          data: {
            "type" => "response.completed",
            "response" => {
              "id" => "resp_456",
              "model" => "gpt-5-mini",
              "usage" => {
                "input_tokens" => 50,
                "output_tokens" => 7,
                "total_tokens" => 57
              }
            }
          }
        }
      ]

      result = parser.parse_stream(
        request_url: responses_url,
        request_body: { model: "gpt-5-mini", stream: true }.to_json,
        response_status: 200,
        events: events
      )

      expect(result.token_usage.input_tokens).to eq(50)
      expect(result.token_usage.output_tokens).to eq(7)
      expect(result.token_usage.total_tokens).to eq(57)
      expect(result.usage_source).to eq(:stream_final)
      expect(result.provider_response_id).to eq("resp_456")
    end

    it "extracts Realtime response.done audio token details" do
      events = [
        {
          event: "response.done",
          data: {
            "type" => "response.done",
            "response" => {
              "id" => "resp_456",
              "model" => "gpt-realtime-1.5",
              "usage" => {
                "input_tokens" => 132,
                "input_token_details" => { "cached_tokens" => 64, "audio_tokens" => 13 },
                "output_tokens" => 121,
                "output_token_details" => { "audio_tokens" => 91 },
                "total_tokens" => 253
              }
            }
          }
        }
      ]

      result = parser.parse_stream(
        request_url: responses_url,
        request_body: { model: "gpt-realtime-1.5", stream: true }.to_json,
        response_status: 200,
        events: events
      )

      expect(result.token_usage.input_tokens).to eq(55)
      expect(result.token_usage.cache_read_input_tokens).to eq(64)
      expect(result.token_usage.audio_input_tokens).to eq(13)
      expect(result.token_usage.output_tokens).to eq(30)
      expect(result.token_usage.audio_output_tokens).to eq(91)
      expect(result.token_usage.total_tokens).to eq(253)
    end

    it "captures Responses API streamed hosted tool output items once" do
      events = [
        {
          event: "response.output_item.done",
          data: {
            "type" => "response.output_item.done",
            "item" => {
              "type" => "web_search_call",
              "id" => "ws_456",
              "status" => "completed",
              "action" => { "type" => "search" }
            }
          }
        },
        {
          event: "response.completed",
          data: {
            "type" => "response.completed",
            "response" => {
              "id" => "resp_456",
              "model" => "gpt-5-mini",
              "output" => [
                {
                  "type" => "web_search_call",
                  "id" => "ws_456",
                  "status" => "completed",
                  "action" => { "type" => "search" }
                },
                {
                  "type" => "file_search_call",
                  "id" => "fs_456",
                  "status" => "completed"
                }
              ],
              "usage" => {
                "input_tokens" => 50,
                "output_tokens" => 7,
                "total_tokens" => 57
              }
            }
          }
        }
      ]

      result = parser.parse_stream(
        request_url: responses_url,
        request_body: { model: "gpt-5-mini", stream: true }.to_json,
        response_status: 200,
        events: events
      )

      service_lines = result.line_items.reject { |item| item.unit == :token }
      expect(service_lines.map(&:kind)).to eq(%i[web_search_request file_search_call])
      expect(service_lines.map(&:provider_item_id)).to eq(%w[ws_456 fs_456])
    end

    it "extracts model identifiers from Responses API stream events" do
      events = [
        {
          event: nil,
          data: { "type" => "response.created", "response" => { "id" => "resp_456", "model" => "gpt-5-mini" } }
        },
        { event: nil, data: { "usage" => { "input_tokens" => 12, "output_tokens" => 3, "total_tokens" => 15 } } }
      ]

      result = parser.parse_stream(
        request_url: responses_url,
        request_body: {}.to_json,
        response_status: 200,
        events: events
      )

      expect(result.model).to eq("gpt-5-mini")
    end

    it "returns an unknown-usage UsageCapture when no usage chunk arrives" do
      events = [
        { event: nil, data: { "model" => "gpt-4o", "choices" => [{ "delta" => { "content" => "hi" } }] } }
      ]

      result = nil
      expect(LlmCostTracker::Logging).to receive(:warn).with(/stream_options.*include_usage/).once
      result = parser.parse_stream(
        request_url: chat_completions_url,
        request_body: request_body,
        response_status: 200,
        events: events
      )

      expect(result.stream).to be true
      expect(result.usage_source).to eq(:unknown)
      expect(result.token_usage.input_tokens).to eq(0)
      expect(result.token_usage.output_tokens).to eq(0)
      expect(result.provider_response_id).to be_nil
    end

    it "does not warn about stream_options when chat-completions request already opts into usage" do
      events = [
        { event: nil, data: { "model" => "gpt-4o", "choices" => [{ "delta" => { "content" => "hi" } }] } }
      ]

      expect(LlmCostTracker::Logging).not_to receive(:warn)
      parser.parse_stream(
        request_url: chat_completions_url,
        request_body: { model: "gpt-4o", stream: true, stream_options: { include_usage: true } }.to_json,
        response_status: 200,
        events: events
      )
    end

    it "does not warn about stream_options for the Responses API where usage is automatic" do
      events = [
        {
          event: nil,
          data: { "type" => "response.created", "response" => { "id" => "resp_x", "model" => "gpt-5-mini" } }
        }
      ]

      expect(LlmCostTracker::Logging).not_to receive(:warn)
      parser.parse_stream(
        request_url: responses_url,
        request_body: { model: "gpt-5-mini", stream: true }.to_json,
        response_status: 200,
        events: events
      )
    end

    it "computes stream total tokens when the final usage omits total_tokens" do
      events = [
        {
          event: nil,
          data: { "type" => "response.created", "response" => { "id" => "resp_456", "model" => "gpt-5-mini" } }
        },
        {
          event: nil,
          data: {
            "usage" => {
              "input_tokens" => 20,
              "input_tokens_details" => { "cached_tokens" => 7, "audio_tokens" => 5 },
              "output_tokens" => 8,
              "output_tokens_details" => { "audio_tokens" => 3 }
            }
          }
        }
      ]

      result = parser.parse_stream(
        request_url: responses_url,
        request_body: { model: "gpt-5-mini", stream: true }.to_json,
        response_status: 200,
        events: events
      )

      expect(result.token_usage.input_tokens).to eq(8)
      expect(result.token_usage.cache_read_input_tokens).to eq(7)
      expect(result.token_usage.audio_input_tokens).to eq(5)
      expect(result.token_usage.output_tokens).to eq(5)
      expect(result.token_usage.audio_output_tokens).to eq(3)
      expect(result.token_usage.total_tokens).to eq(28)
    end

    it "returns nil on non-200 responses" do
      result = parser.parse_stream(
        request_url: chat_completions_url,
        request_body: request_body,
        response_status: 500
      )

      expect(result).to be_nil
    end
  end
end
