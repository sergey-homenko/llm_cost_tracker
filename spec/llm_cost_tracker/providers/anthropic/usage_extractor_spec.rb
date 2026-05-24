# frozen_string_literal: true

require "spec_helper"
require "llm_cost_tracker/providers/anthropic/usage_extractor"

RSpec.describe LlmCostTracker::Providers::Anthropic::UsageExtractor do
  describe ".token_usage" do
    it "extracts input, output, cache_read, and structured cache writes" do
      result = described_class.token_usage(
        input_tokens: 200, output_tokens: 80, cache_read_input_tokens: 50,
        cache_creation: { ephemeral_5m_input_tokens: 20, ephemeral_1h_input_tokens: 10 }
      )

      expect(result.input_tokens).to eq(200)
      expect(result.output_tokens).to eq(80)
      expect(result.cache_read_input_tokens).to eq(50)
      expect(result.cache_write_input_tokens).to eq(20)
      expect(result.cache_write_extended_input_tokens).to eq(10)
    end

    it "falls back to flat cache_creation_input_tokens when structured form is absent" do
      result = described_class.token_usage(input_tokens: 200, output_tokens: 80, cache_creation_input_tokens: 30)
      expect(result.cache_write_input_tokens).to eq(30)
      expect(result.cache_write_extended_input_tokens).to eq(0)
    end

    it "warns when cache_creation has an unexpected shape and no flat fallback" do
      allow(LlmCostTracker::Logging).to receive(:warn)
      described_class.token_usage(input_tokens: 200, output_tokens: 80, cache_creation: "unexpected")
      expect(LlmCostTracker::Logging).to have_received(:warn).with(include("String"))
    end

    it "extracts thinking_tokens as hidden_output_tokens" do
      result = described_class.token_usage(input_tokens: 200, output_tokens: 80, thinking_tokens: 6)
      expect(result.hidden_output_tokens).to eq(6)
    end

    it "uses thinking_output_tokens as a fallback for hidden_output_tokens" do
      result = described_class.token_usage(input_tokens: 200, output_tokens: 80, thinking_output_tokens: 7)
      expect(result.hidden_output_tokens).to eq(7)
    end

    it "uses output_tokens_details.reasoning_tokens as a final hidden_output fallback" do
      result = described_class.token_usage(
        input_tokens: 200, output_tokens: 80,
        output_tokens_details: { reasoning_tokens: 8 }
      )
      expect(result.hidden_output_tokens).to eq(8)
    end
  end

  describe ".pricing_mode" do
    it "returns nil for standard-equivalent service tiers" do
      expect(described_class.pricing_mode(request: {}, usage: { input_tokens: 1, output_tokens: 1, service_tier: "priority" })).to be_nil
    end

    it "captures the batch service tier as :batch" do
      expect(described_class.pricing_mode(request: {}, usage: { input_tokens: 1, output_tokens: 1, service_tier: "batch" })).to eq("batch")
    end

    it "combines speed and inference_geo into fast_data_residency" do
      expect(described_class.pricing_mode(request: {}, usage: { input_tokens: 1, output_tokens: 1, speed: "fast", inference_geo: "us" })).to eq("fast_data_residency")
    end

    it "ignores inference_geo values outside the documented uplift list" do
      expect(described_class.pricing_mode(request: {}, usage: { input_tokens: 1, output_tokens: 1, inference_geo: "global" })).to be_nil
    end

    it "falls back to request fields when usage is nil" do
      expect(described_class.pricing_mode(request: { speed: "fast", inference_geo: "us" }, usage: nil)).to eq("fast_data_residency")
    end
  end

  describe ".service_line_items" do
    it "emits one line item per non-zero server_tool_use count" do
      items = described_class.service_line_items(
        input_tokens: 1, output_tokens: 1,
        server_tool_use: { web_search_requests: 2, web_fetch_requests: 1, code_execution_requests: 0 }
      )

      expect(items.map(&:kind)).to eq(%w[web_search_request web_fetch_request])
      expect(items.map(&:quantity).map(&:to_i)).to eq([2, 1])
      expect(items.map(&:cost_status).uniq).to eq([LlmCostTracker::Billing::CostStatus::UNKNOWN])
    end

    it "returns an empty array when server_tool_use is absent" do
      expect(described_class.service_line_items(input_tokens: 1, output_tokens: 1)).to eq([])
    end
  end
end
