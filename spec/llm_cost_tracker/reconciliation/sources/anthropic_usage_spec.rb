# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe LlmCostTracker::Reconciliation::Sources::AnthropicUsage do
  let(:bucket_starts_at) { "2026-05-01T00:00:00Z" }
  let(:bucket_ends_at) { "2026-05-02T00:00:00Z" }

  let(:response) do
    {
      "data" => [
        {
          "starts_at" => bucket_starts_at,
          "ends_at" => bucket_ends_at,
          "results" => [
            {
              "amount" => "1.50",
              "currency" => "USD",
              "model" => "claude-haiku-4-5",
              "workspace_id" => "wrkspc_main",
              "api_key_id" => "apikey_alpha",
              "service_tier" => "standard",
              "context_window" => "0_to_200k",
              "token_type" => "input",
              "description" => "Input tokens"
            },
            {
              "amount" => "2.00",
              "currency" => "USD",
              "model" => "claude-haiku-4-5",
              "workspace_id" => "wrkspc_main",
              "service_tier" => "priority",
              "token_type" => "output",
              "description" => "Output tokens (priority)"
            }
          ]
        }
      ],
      "has_more" => false
    }
  end

  describe ".parse" do
    it "produces a row per cost result with the meter envelope filled in" do
      rows = described_class.parse(response)

      expect(rows.size).to eq(2)
      first = rows.first
      expect(first).to include(
        period_start: Date.new(2026, 5, 1),
        period_end: Date.new(2026, 5, 1),
        billed_amount: "1.50",
        currency: "USD"
      )
      expect(first[:metadata]).to include(
        "row_type" => "cost",
        "meter" => "input_tokens",
        "authority" => "cost_api",
        "match_basis" => "api_key",
        "model" => "claude-haiku-4-5",
        "provider_workspace_id" => "wrkspc_main",
        "provider_api_key_id" => "apikey_alpha",
        "context_window" => "0_to_200k"
      )
      expect(first[:external_id]).to start_with("cost-")
    end

    it "captures non-standard service tiers as pricing_mode" do
      rows = described_class.parse(response)

      output_row = rows.find { |row| row[:metadata]["token_type"] == "output" }
      expect(output_row[:metadata]["pricing_mode"]).to eq("priority")
    end

    it "labels cache and tool meters from token_type and description" do
      response[:data] = [{
        "starts_at" => bucket_starts_at,
        "ends_at" => bucket_ends_at,
        "results" => [
          { "amount" => "0.10", "token_type" => "cache_read_input", "description" => "Cache read" },
          { "amount" => "0.20", "token_type" => "cache_creation_input", "description" => "Cache creation" },
          { "amount" => "0.05", "description" => "Web search request" },
          { "amount" => "0.50", "description" => "Code execution hour" }
        ]
      }]

      meters = described_class.parse(response).map { |row| row[:metadata]["meter"] }
      expect(meters).to eq(%w[cache_read_input_tokens cache_creation_input_tokens web_search code_execution_hour])
    end

    it "skips results without an amount" do
      response[:data] = [{
        "starts_at" => bucket_starts_at,
        "ends_at" => bucket_ends_at,
        "results" => [
          { "currency" => "USD", "token_type" => "input" },
          { "amount" => "0.50", "token_type" => "input" }
        ]
      }]

      expect(described_class.parse(response).size).to eq(1)
    end

    it "skips buckets without start and end timestamps" do
      response[:data] = [{ "results" => [{ "amount" => "1.00" }] }]

      expect(described_class.parse(response)).to be_empty
    end

    it "differentiates rows that share a model but differ on workspace" do
      response[:data] = [{
        "starts_at" => bucket_starts_at,
        "ends_at" => bucket_ends_at,
        "results" => [
          { "amount" => "1.00", "model" => "claude-haiku-4-5", "workspace_id" => "ws_a", "token_type" => "input" },
          { "amount" => "2.00", "model" => "claude-haiku-4-5", "workspace_id" => "ws_b", "token_type" => "input" }
        ]
      }]

      rows = described_class.parse(response)
      expect(rows.map { |row| row[:external_id] }.uniq.size).to eq(2)
    end

    it "accepts JSON string responses" do
      rows = described_class.parse(response.to_json)

      expect(rows.size).to eq(2)
    end

    it "raises a parse error rather than silently dropping malformed JSON" do
      expect { described_class.parse("{ not-json") }
        .to raise_error(ArgumentError, /Unable to parse Anthropic Usage payload/)
    end

    it "is empty for nil input" do
      expect(described_class.parse(nil)).to eq([])
    end

    it "falls back to period_only match_basis when no attribution dimension is present" do
      response[:data] = [{
        "starts_at" => bucket_starts_at,
        "ends_at" => bucket_ends_at,
        "results" => [{ "amount" => "1.00", "token_type" => "input" }]
      }]

      expect(described_class.parse(response).first[:metadata]["match_basis"]).to eq("period_only")
    end

    it "falls back to the default meter when the line cannot be classified" do
      response[:data] = [{
        "starts_at" => bucket_starts_at,
        "ends_at" => bucket_ends_at,
        "results" => [{ "amount" => "1.00", "description" => "unknown subscription line" }]
      }]

      expect(described_class.parse(response).first[:metadata]["meter"]).to eq("tokens")
    end

    it "tags data_residency as a pricing_mode modifier" do
      response[:data] = [{
        "starts_at" => bucket_starts_at,
        "ends_at" => bucket_ends_at,
        "results" => [{
          "amount" => "1.00", "token_type" => "input",
          "service_tier" => "priority", "data_residency" => true
        }]
      }]

      expect(described_class.parse(response).first[:metadata]["pricing_mode"])
        .to eq("data_residency_priority")
    end

    it "accepts epoch timestamps for bucket bounds" do
      response[:data] = [{
        "starts_at" => Time.utc(2026, 5, 1).to_i,
        "ends_at" => Time.utc(2026, 5, 2).to_i,
        "results" => [{ "amount" => "1.00", "token_type" => "input" }]
      }]

      expect(described_class.parse(response).first[:period_start]).to eq(Date.new(2026, 5, 1))
    end

    it "raises when the JSON payload is not an object" do
      expect { described_class.parse("[1, 2]") }
        .to raise_error(ArgumentError, /must be a JSON object/)
    end

    it "produces rows in the shape Reconciliation.import expects" do
      rows = described_class.parse(response)

      rows.each do |row|
        expect(row.keys).to include(:external_id, :period_start, :period_end, :billed_amount, :currency, :metadata)
        expect(row[:period_start]).to be_a(Date)
        expect(row[:metadata]).to include("row_type", "meter", "authority", "match_basis")
      end
    end
  end
end
