# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Integrations::RubyLlm::V1::Reply do
  let(:tokens) { Struct.new(:input, :output, :cache_read, :cache_write, :thinking, keyword_init: true) }
  let(:message) { Struct.new(:raw, :tokens, :model_id) }

  def provider(slug) = Struct.new(:slug, :api_base).new(slug, "https://api.example.com/v1")

  def reply(slug, body, **counts)
    described_class.new(provider(slug), message.new(body, tokens.new(**counts), "model-x"), "requested-model")
  end

  it "corrects RubyLLM's counts from the raw usage: Bedrock's uncached input, Anthropic's cumulative input " \
     "and reasoning that a provider totals apart from its output" do
    bedrock = reply("bedrock", { "usage" => { "inputTokens" => 3000 } }, input: 1000, output: 400)
    anthropic = reply("anthropic", { "usage" => { "input_tokens" => 10_682 } }, input: 2679, output: 510)
    xai = reply("xai", { "usage" => { "prompt_tokens" => 120, "total_tokens" => 150 } }, input: 120, output: 5,
                                                                                          thinking: 25)

    expect(bedrock.token_counts).to include(input: 3000, output: 400)
    expect(anthropic.token_counts).to include(input: 10_682, output: 510)
    expect(xai.token_counts).to include(input: 120, output: 30, thinking: 25)
  end

  it "splits cache writes by Anthropic's cache_creation and Bedrock's cacheDetails, and prices Gemini from its " \
     "usageMetadata" do
    cache_creation = { "ephemeral_5m_input_tokens" => 100, "ephemeral_1h_input_tokens" => 200 }
    cache_details = [{ "ttl" => "1h", "inputTokens" => 3000 }, { "ttl" => "5m", "inputTokens" => 1000 }]
    splits = { "anthropic" => [{ "cache_creation" => cache_creation }, 350],
               "bedrock" => [{ "cacheDetails" => cache_details }, 4000],
               "deepseek" => [{}, 50] }.map do |slug, (usage, total)|
      written = reply(slug, { "usage" => usage }, input: 10, output: 5, cache_write: total).event(stream: false)
      written.token_usage.to_h.values_at(:cache_write_input_tokens, :cache_write_extended_input_tokens)
    end
    usage_metadata = { "promptTokenCount" => 40, "candidatesTokenCount" => 5 }
    gemini = reply("gemini", { "usageMetadata" => usage_metadata, "responseId" => "gem_1" }, input: 1, output: 1)

    expect(splits).to eq([[150, 200], [1000, 3000], [50, 0]])
    expect(gemini.event(stream: true)).to have_attributes(provider: "gemini", model: "model-x", stream: true,
                                                          provider_response_id: "gem_1")
    expect(gemini.event(stream: true).token_usage).to have_attributes(input_tokens: 40, output_tokens: 5)
  end

  it "reads each provider's pricing mode and service charges from the body" do
    modes = { "anthropic" => { "usage" => { "service_tier" => "priority" } },
              "bedrock" => { "serviceTier" => { "type" => "flex" } }, "openai" => { "service_tier" => "flex" },
              "mistral" => { "usage" => { "service_tier" => "priority" } }, "gemini" => {},
              "deepseek" => { "service_tier" => "off_peak" } }
            .map { |slug, body| reply(slug, body, input: 1, output: 1).event(stream: false).pricing_mode }
    charges = { "anthropic" => { "usage" => { "server_tool_use" => { "web_search_requests" => 2 } } },
                "gemini" => { "candidates" => [{ "groundingMetadata" => { "webSearchQueries" => ["q"] } }] },
                "openrouter" => { "usage" => { "cost" => 0.0063 } }, "openai" => {}, "deepseek" => {} }
              .map { |slug, body| reply(slug, body).service_line_items.map(&:kind) }

    expect(modes).to eq(["priority", "flex", "flex", "priority", nil, "off_peak"])
    expect(charges).to eq([%w[web_search_request], %w[grounding_request], %w[billed_request], [], []])
  end

  it "reads the usage the integration kept on a response whose raw body is not JSON, and its id" do
    raw = Faraday::Response.new(status: 200, response_body: "data: {}")
    raw.instance_variable_set(described_class::KEPT_BODY, { "usage" => { "input_tokens" => 7 }, "id" => "msg_1" })
    kept = Struct.new(:input_tokens).new(7)
    kept.instance_variable_set(described_class::KEPT_BODY, { "usageMetadata" => {} })

    expect(described_class.response_id(message.new(raw))).to eq("msg_1")
    expect(described_class.body(kept)).to eq("usageMetadata" => {})
    expect(described_class.body(Struct.new(:raw).new("plain text"))).to eq({})
  end

  it "records nothing for a reply without counts or charges unless the caller marks its usage as unknown" do
    bare = described_class.new(provider("openai"), Struct.new(:model).new("whisper-1"), "requested-model")

    expect(bare.event(stream: false)).to be_nil
    expect(bare.event(stream: false, usage_source: "unknown"))
      .to have_attributes(model: "whisper-1", usage_source: "unknown", provider_response_id: nil)
  end
end
