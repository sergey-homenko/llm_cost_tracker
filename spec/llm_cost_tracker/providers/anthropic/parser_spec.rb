# frozen_string_literal: true

require "spec_helper"
require "uri"

RSpec.describe LlmCostTracker::Providers::Anthropic::Parser do
  subject(:parser) { described_class.new }

  let(:anthropic_messages_url) { URI::HTTPS.build(host: "api.anthropic.com", path: "/v1/messages").to_s }
  let(:openai_chat_url) { URI::HTTPS.build(host: "api.openai.com", path: "/v1/chat/completions").to_s }

  def priced(event)
    LlmCostTracker::Pricing::Calculation.for(provider: event.provider, model: event.model, tokens: event.token_usage,
                                             line_items: event.line_items, pricing_mode: event.pricing_mode,
                                             usage_source: event.usage_source)
  end

  def parse_body(model, body)
    parser.parse(request_url: anthropic_messages_url, request_body: { model: model }.to_json,
                 response_status: 200, response_body: body.to_json)
  end

  describe "#match?" do
    it_behaves_like "a parser with invalid URL handling"

    it "matches Anthropic messages URL" do
      expect(described_class.match?(anthropic_messages_url)).to be true
    end

    it "does not match OpenAI URLs" do
      expect(described_class.match?(openai_chat_url)).to be false
    end
  end

  describe "#retain_stream_event?" do
    it "keeps fallback blocks from mid-stream so each declined attempt still maps to its trigger" do
      block = ->(type) { { "type" => "content_block_start", "content_block" => { "type" => type } } }

      expect(parser.retain_stream_event?(block.call("fallback"))).to be(true)
      expect(parser.retain_stream_event?(block.call("text"))).to be(false)
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

    # Rates: https://platform.claude.com/docs/en/about-claude/pricing ($/MTok): Fable 5.1 10/50,
    # Opus 5 and Opus 4.8 5/25, Sonnet 5 2/10 with $0.20 cache reads.
    it "prices threshold compaction iterations, which the top-level usage leaves out" do
      # compaction-threshold#understanding-usage: 203,000 x $5 + 4,500 x $25 = $1.1275
      result = parse_body("claude-opus-5", model: "claude-opus-5", usage: {
                            input_tokens: 23_000, output_tokens: 1_000,
                            iterations: [{ type: "compaction", input_tokens: 180_000, output_tokens: 3_500 },
                                         { type: "message", input_tokens: 23_000, output_tokens: 1_000 }]
                          })

      expect(result.token_usage).to have_attributes(input_tokens: 203_000, output_tokens: 4_500)
      expect(priced(result).cost.total).to eq(BigDecimal("1.1275"))
    end

    it "prices an on-demand compaction whose top-level usage is zero instead of recording it free" do
      # compaction-on-demand#count-compaction-usage: 150,000 x $2 + 2,500 x $10 = $0.325
      result = parse_body("claude-sonnet-5", model: "claude-sonnet-5", stop_reason: "compaction", usage: {
                            input_tokens: 0, output_tokens: 0,
                            iterations: [{ type: "compaction", input_tokens: 150_000, output_tokens: 2_500 }]
                          })

      expect(priced(result)).to have_attributes(cost_status: "complete")
      expect(priced(result).cost.total).to eq(BigDecimal("0.325"))
    end

    it "prices advisor iterations at the advisor model's rates on top of the executor's usage" do
      # advisor-tool#usage-and-billing example: Sonnet 5 executor 1,760 x $2 + 412 x $0.20 + 531 x $10 = $0.0089124,
      # Opus 5 advisor 823 x $5 + 1,612 x $25 = $0.044415.
      result = parse_body("claude-sonnet-5", model: "claude-sonnet-5", usage: {
                            input_tokens: 1_760, cache_read_input_tokens: 412, cache_creation_input_tokens: 0,
                            output_tokens: 531,
                            iterations: [
                              { type: "message", input_tokens: 412, cache_read_input_tokens: 0, output_tokens: 89 },
                              { type: "advisor_message", model: "claude-opus-5", input_tokens: 823,
                                cache_read_input_tokens: 0, cache_creation_input_tokens: 0, output_tokens: 1_612 },
                              { type: "message", input_tokens: 1_348, cache_read_input_tokens: 412, output_tokens: 442 }
                            ]
                          })

      expect(result.token_usage).to have_attributes(input_tokens: 1_760, cache_read_input_tokens: 412, output_tokens: 531)
      advisor = priced(result).priced_line_items.find { |item| item.kind == "model_iteration" }
      expect(advisor).to have_attributes(cost: BigDecimal("0.044415"),
                                         provider_field: "usage.iterations.advisor_message")
      expect(advisor.details).to include(model: "claude-opus-5", input_tokens: 823, output_tokens: 1_612)
      expect(priced(result).cost.total).to eq(BigDecimal("0.0533274"))
    end

    it "bills a server-side fallback attempt declined mid-output at the declining model's rates" do
      # refusals-and-fallback#billing-and-rate-limits: Fable 5.1 5,000 x $10 + 1,200 x $50 = $0.11,
      # Opus 4.8 5,200 x $5 + 900 x $25 = $0.0485.
      result = parse_body("claude-fable-5-1", model: "claude-opus-4-8", usage: {
                            input_tokens: 5_200, output_tokens: 900,
                            iterations: [
                              { type: "message", model: "claude-fable-5-1", input_tokens: 5_000, output_tokens: 1_200 },
                              { type: "fallback_message", model: "claude-opus-4-8", input_tokens: 5_200,
                                output_tokens: 900 }
                            ]
                          })

      expect(result.model).to eq("claude-opus-4-8")
      expect(priced(result).cost.total).to eq(BigDecimal("0.1585"))
    end

    # refusals-and-fallback#what-the-response-contains example: Opus 4.8 412 x $5 + 264 x $25 = $0.00866, plus
    # Fable 5's 535 x $10 = $0.00535 only when its trigger category is billed before any output.
    { "cyber" => "0.00866", "bio" => "0.01401" }.each do |category, total|
      it "bills a fallback attempt declined before any output by its #{category} trigger category" do
        result = parse_body("claude-fable-5", model: "claude-opus-4-8", content: [
                              { type: "fallback", from: { model: "claude-fable-5" }, to: { model: "claude-opus-4-8" },
                                trigger: { type: "refusal", category: category } },
                              { type: "text", text: "Hi! How can I help you today?" }
                            ], usage: {
                              input_tokens: 412, output_tokens: 264,
                              iterations: [
                                { type: "message", model: "claude-fable-5", input_tokens: 535, output_tokens: 0 },
                                { type: "fallback_message", model: "claude-opus-4-8", input_tokens: 412,
                                  output_tokens: 264 }
                              ]
                            })

        expect(priced(result).cost.total).to eq(BigDecimal(total))
      end
    end

    it "keeps a call complete when an earlier fallback attempt is billed and the last one refuses unbilled" do
      # Fable 5.1 declined mid-output (5,000 x $10 + 1,200 x $50 = $0.11); Opus 5's general_harms refusal is not billed.
      result = parse_body("claude-fable-5-1", model: "claude-opus-5", content: [], stop_reason: "refusal",
                                              stop_details: { type: "refusal", category: "general_harms" }, usage: {
                                                input_tokens: 5_200, output_tokens: 0,
                                                iterations: [
                                                  { type: "message", model: "claude-fable-5-1", input_tokens: 5_000,
                                                    output_tokens: 1_200 },
                                                  { type: "fallback_message", model: "claude-opus-5",
                                                    input_tokens: 5_200, output_tokens: 0 }
                                                ]
                                              })

      expect(priced(result)).to have_attributes(cost_status: "complete")
      expect(priced(result).cost.total).to eq(BigDecimal("0.11"))
    end

    it "keeps a call partial when a billed fallback attempt's model has no rates and the last one refuses unbilled" do
      # refusals-and-fallback#how-refusals-are-billed: the bio decline is billed, Opus 5's cyber refusal is not.
      result = parse_body("claude-opus-6", model: "claude-opus-5", stop_reason: "refusal", content: [
                            { type: "fallback", from: { model: "claude-opus-6" }, to: { model: "claude-opus-5" },
                              trigger: { type: "refusal", category: "bio" } }
                          ], stop_details: { type: "refusal", category: "cyber" }, usage: {
                            input_tokens: 2_400, output_tokens: 0,
                            iterations: [
                              { type: "message", model: "claude-opus-6", input_tokens: 2_400, output_tokens: 0 },
                              { type: "fallback_message", model: "claude-opus-5", input_tokens: 2_400,
                                output_tokens: 0 }
                            ]
                          })

      expect(priced(result)).to have_attributes(cost_status: "partial")
      expect(priced(result).cost.total).to eq(0)
    end

    it "prices a fast executor's advisor at standard speed when the advisor model has no fast mode" do
      # fast-mode#supported-models: Opus 5.5, Opus 5 and Opus 4.8 only. Opus 5 fast 2,000 x $10 + 300 x $50 = $0.035;
      # advisor-tool#usage-and-billing, Fable 5.1 standard rates: 1,500 x $10 + 1,000 x $50 = $0.065.
      result = parse_body("claude-opus-5", model: "claude-opus-5", usage: {
                            input_tokens: 2_000, output_tokens: 300, speed: "fast",
                            iterations: [
                              { type: "advisor_message", model: "claude-fable-5-1", input_tokens: 1_500,
                                output_tokens: 1_000 }
                            ]
                          })

      expect(result.pricing_mode).to eq("fast")
      expect(priced(result)).to have_attributes(cost_status: "complete")
      expect(priced(result).cost.total).to eq(BigDecimal("0.1"))
    end

    it "bills a refused on-demand compaction that produced summary output" do
      # compaction-on-demand#when-no-summary-comes-back: a refusal is still billed; the output was already produced.
      # Opus 5: 150,000 x $5 + 2,500 x $25 = $0.8125.
      result = parse_body("claude-opus-5", model: "claude-opus-5", content: [], stop_reason: "refusal",
                                           stop_details: { type: "refusal", category: "cyber" }, usage: {
                                             input_tokens: 0, output_tokens: 0,
                                             iterations: [{ type: "compaction", input_tokens: 150_000,
                                                            output_tokens: 2_500 }]
                                           })

      expect(priced(result)).to have_attributes(cost_status: "complete")
      expect(priced(result).cost.total).to eq(BigDecimal("0.8125"))
    end

    it "records a pre-output refusal in an unbilled category at $0 and keeps its token counts" do
      # refusals-and-fallback#how-refusals-are-billed: cyber refusals before any output are not billed.
      result = parse_body("claude-fable-5-1", model: "claude-fable-5-1", content: [], stop_reason: "refusal",
                                              stop_details: { type: "refusal", category: "cyber" },
                                              usage: { input_tokens: 412, output_tokens: 0 })

      expect(result.token_usage.input_tokens).to eq(412)
      expect(priced(result)).to have_attributes(cost_status: "free")
      expect(priced(result).cost.total).to eq(0)
    end

    it "bills a pre-output refusal in a billed category" do
      # bio refusals before any output are billed at the model's rates: 412 x $10 = $0.00412
      result = parse_body("claude-fable-5-1", model: "claude-fable-5-1", content: [], stop_reason: "refusal",
                                              stop_details: { type: "refusal", category: "bio" },
                                              usage: { input_tokens: 412, output_tokens: 0 })

      expect(priced(result)).to have_attributes(cost_status: "complete")
      expect(priced(result).cost.total).to eq(BigDecimal("0.00412"))
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

    it "records a mid-output fallback under the model that served it" do
      # refusals-and-fallback#streaming: message_start names the declining model. Fable 5.1 5,000 x $10 + 1,200 x $50
      # plus Opus 4.8 5,200 x $5 + 900 x $25 = $0.1585.
      events = [
        { event: "message_start", data: {
          "type" => "message_start",
          "message" => { "id" => "msg_fb", "model" => "claude-fable-5-1",
                         "usage" => { "input_tokens" => 5_000, "output_tokens" => 1 } }
        } },
        { event: "content_block_start", data: {
          "type" => "content_block_start", "index" => 1,
          "content_block" => { "type" => "fallback", "from" => { "model" => "claude-fable-5-1" },
                               "to" => { "model" => "claude-opus-4-8" } }
        } },
        { event: "message_delta", data: {
          "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" },
          "usage" => { "input_tokens" => 5_200, "output_tokens" => 900, "iterations" => [
            { "type" => "message", "model" => "claude-fable-5-1", "input_tokens" => 5_000, "output_tokens" => 1_200 },
            { "type" => "fallback_message", "model" => "claude-opus-4-8", "input_tokens" => 5_200, "output_tokens" => 900 }
          ] }
        } }
      ]

      result = parser.parse_stream(request_url: anthropic_messages_url, request_body: request_body,
                                   response_status: 200, events: events)

      expect(result.model).to eq("claude-opus-4-8")
      expect(priced(result).cost.total).to eq(BigDecimal("0.1585"))
    end

    it "bills a streamed pre-output fallback attempt whose fallback block's category is billed" do
      # refusals-and-fallback#streaming: Fable 5 535 x $10 = $0.00535 plus Opus 4.8 412 x $5 + 264 x $25 = $0.00866.
      events = [
        { event: "message_start", data: {
          "type" => "message_start",
          "message" => { "id" => "msg_fb", "model" => "claude-opus-4-8",
                         "usage" => { "input_tokens" => 412, "output_tokens" => 1 } }
        } },
        { event: "content_block_start", data: {
          "type" => "content_block_start", "index" => 0,
          "content_block" => { "type" => "fallback", "from" => { "model" => "claude-fable-5" },
                               "to" => { "model" => "claude-opus-4-8" },
                               "trigger" => { "type" => "refusal", "category" => "bio" } }
        } },
        { event: "message_delta", data: {
          "type" => "message_delta", "delta" => { "stop_reason" => "end_turn" },
          "usage" => { "output_tokens" => 264, "iterations" => [
            { "type" => "message", "model" => "claude-fable-5", "input_tokens" => 535, "output_tokens" => 0 },
            { "type" => "fallback_message", "model" => "claude-opus-4-8", "input_tokens" => 412, "output_tokens" => 264 }
          ] }
        } }
      ]

      result = parser.parse_stream(request_url: anthropic_messages_url, request_body: request_body,
                                   response_status: 200, events: events)

      expect(priced(result).cost.total).to eq(BigDecimal("0.01401"))
    end

    it "records a streamed pre-output refusal with a null category at $0" do
      events = [
        { event: "message_start", data: {
          "type" => "message_start",
          "message" => { "id" => "msg_ref", "model" => "claude-fable-5-1",
                         "usage" => { "input_tokens" => 412, "output_tokens" => 0 } }
        } },
        { event: "message_delta", data: {
          "type" => "message_delta",
          "delta" => { "stop_reason" => "refusal", "stop_details" => { "type" => "refusal", "category" => nil } },
          "usage" => { "output_tokens" => 0 }
        } }
      ]

      result = parser.parse_stream(request_url: anthropic_messages_url, request_body: request_body,
                                   response_status: 200, events: events)

      expect(priced(result)).to have_attributes(cost_status: "free")
      expect(priced(result).cost.total).to eq(0)
    end
  end
end
