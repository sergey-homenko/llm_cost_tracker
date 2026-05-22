# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe LlmCostTracker::Providers::Anthropic::ReconciliationSource do
  let(:bucket_starting_at) { "2026-05-01T00:00:00Z" }
  let(:bucket_ending_at) { "2026-05-02T00:00:00Z" }

  let(:response) do
    {
      "data" => [
        {
          "starting_at" => bucket_starting_at,
          "ending_at" => bucket_ending_at,
          "results" => [
            {
              "amount" => "1.50",
              "currency" => "USD",
              "model" => "claude-haiku-4-5",
              "workspace_id" => "wrkspc_main",
              "service_tier" => "standard",
              "context_window" => "0-200k",
              "cost_type" => "tokens",
              "token_type" => "uncached_input_tokens",
              "description" => "Input tokens"
            },
            {
              "amount" => "2.00",
              "currency" => "USD",
              "model" => "claude-haiku-4-5",
              "workspace_id" => "wrkspc_main",
              "service_tier" => "standard",
              "context_window" => "0-200k",
              "cost_type" => "tokens",
              "token_type" => "output_tokens",
              "description" => "Output tokens"
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
        billed_amount: "0.015",
        currency: "USD"
      )
      expect(first[:metadata]).to include(
        "row_type" => "cost",
        "meter" => "input_tokens",
        "authority" => "cost_api",
        "match_basis" => "workspace",
        "model" => "claude-haiku-4-5",
        "provider_workspace_id" => "wrkspc_main",
        "context_window" => "0-200k",
        "cost_type" => "tokens",
        "token_type" => "uncached_input_tokens"
      )
      expect(first[:external_id]).to start_with("cost-")
    end

    it "converts the cost API amount from cents to dollars" do
      response[:data] = [{
        "starting_at" => bucket_starting_at,
        "ending_at" => bucket_ending_at,
        "results" => [
          { "amount" => "12345", "currency" => "USD", "cost_type" => "tokens", "token_type" => "uncached_input_tokens" }
        ]
      }]

      expect(described_class.parse(response).first[:billed_amount]).to eq("123.45")
    end

    it "classifies output tokens from token_type" do
      rows = described_class.parse(response)

      output_row = rows.find { |row| row[:metadata]["token_type"] == "output_tokens" }
      expect(output_row[:metadata]["meter"]).to eq("output_tokens")
      expect(output_row[:metadata]["pricing_mode"]).to be_nil
    end

    it "classifies meters by cost_type and Anthropic token_type tags" do
      response[:data] = [{
        "starting_at" => bucket_starting_at,
        "ending_at" => bucket_ending_at,
        "results" => [
          { "amount" => "0.10", "cost_type" => "tokens", "token_type" => "cache_read_input_tokens" },
          { "amount" => "0.20", "cost_type" => "tokens",
            "token_type" => "cache_creation.ephemeral_5m_input_tokens" },
          { "amount" => "0.25", "cost_type" => "tokens",
            "token_type" => "cache_creation.ephemeral_1h_input_tokens" },
          { "amount" => "0.05", "cost_type" => "web_search", "description" => "Web search requests" },
          { "amount" => "0.50", "cost_type" => "code_execution", "description" => "Code execution sessions" },
          { "amount" => "0.30", "cost_type" => "session_usage", "description" => "Claude Code session" }
        ]
      }]

      meters = described_class.parse(response).map { |row| row[:metadata]["meter"] }
      expect(meters).to eq(%w[cache_read_input_tokens cache_creation_input_tokens cache_creation_input_tokens
                              web_search code_execution_hour session_usage])
    end

    it "skips results without an amount" do
      response[:data] = [{
        "starting_at" => bucket_starting_at,
        "ending_at" => bucket_ending_at,
        "results" => [
          { "currency" => "USD", "cost_type" => "tokens", "token_type" => "uncached_input_tokens" },
          { "amount" => "0.50", "cost_type" => "tokens", "token_type" => "uncached_input_tokens" }
        ]
      }]

      expect(described_class.parse(response).size).to eq(1)
    end

    it "skips buckets without start and end timestamps" do
      response[:data] = [{ "results" => [{ "amount" => "1.00" }] }]

      expect(described_class.parse(response)).to be_empty
    end

    it "falls back to the raw value when a timestamp cannot be parsed" do
      response[:data] = [{
        "starting_at" => "garbage", "ending_at" => bucket_ending_at,
        "results" => [{ "amount" => "1.00", "cost_type" => "tokens", "token_type" => "uncached_input_tokens" }]
      }]

      expect { described_class.parse(response) }.not_to raise_error
    end

    it "differentiates rows that share a model but differ on workspace" do
      response[:data] = [{
        "starting_at" => bucket_starting_at,
        "ending_at" => bucket_ending_at,
        "results" => [
          { "amount" => "1.00", "model" => "claude-haiku-4-5", "workspace_id" => "ws_a",
            "cost_type" => "tokens", "token_type" => "uncached_input_tokens" },
          { "amount" => "2.00", "model" => "claude-haiku-4-5", "workspace_id" => "ws_b",
            "cost_type" => "tokens", "token_type" => "uncached_input_tokens" }
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
        "starting_at" => bucket_starting_at,
        "ending_at" => bucket_ending_at,
        "results" => [{ "amount" => "1.00", "cost_type" => "tokens", "token_type" => "uncached_input_tokens" }]
      }]

      expect(described_class.parse(response).first[:metadata]["match_basis"]).to eq("period_only")
    end

    it "falls back to model match_basis when only model is present" do
      response[:data] = [{
        "starting_at" => bucket_starting_at,
        "ending_at" => bucket_ending_at,
        "results" => [{
          "amount" => "1.00",
          "cost_type" => "tokens",
          "token_type" => "uncached_input_tokens",
          "model" => "claude-3-5-sonnet"
        }]
      }]

      expect(described_class.parse(response).first[:metadata]["match_basis"]).to eq("model")
    end

    it "falls back to the default meter when the cost line cannot be classified" do
      response[:data] = [{
        "starting_at" => bucket_starting_at,
        "ending_at" => bucket_ending_at,
        "results" => [{ "amount" => "1.00", "description" => "unknown subscription line" }]
      }]

      expect(described_class.parse(response).first[:metadata]["meter"]).to eq("tokens")
    end

    it "tags pricing_mode as data_residency when inference_geo is us" do
      response[:data] = [{
        "starting_at" => bucket_starting_at,
        "ending_at" => bucket_ending_at,
        "results" => [{
          "amount" => "1.00", "cost_type" => "tokens", "token_type" => "uncached_input_tokens",
          "inference_geo" => "us"
        }]
      }]

      row = described_class.parse(response).first
      expect(row[:metadata]).to include("inference_geo" => "us")
      expect(row[:metadata]["pricing_mode"]).to eq("data_residency")
    end

    it "tags pricing_mode as batch when service_tier is batch" do
      response[:data] = [{
        "starting_at" => bucket_starting_at,
        "ending_at" => bucket_ending_at,
        "results" => [{
          "amount" => "1.00", "cost_type" => "tokens", "token_type" => "uncached_input_tokens",
          "service_tier" => "batch"
        }]
      }]

      expect(described_class.parse(response).first[:metadata]["pricing_mode"]).to eq("batch")
    end

    it "combines batch and data_residency when both apply" do
      response[:data] = [{
        "starting_at" => bucket_starting_at,
        "ending_at" => bucket_ending_at,
        "results" => [{
          "amount" => "1.00", "cost_type" => "tokens", "token_type" => "uncached_input_tokens",
          "service_tier" => "batch", "inference_geo" => "us"
        }]
      }]

      expect(described_class.parse(response).first[:metadata]["pricing_mode"]).to eq("batch_data_residency")
    end

    it "ignores non-US inference_geo values that do not map to a documented uplift" do
      response[:data] = [{
        "starting_at" => bucket_starting_at,
        "ending_at" => bucket_ending_at,
        "results" => [{
          "amount" => "1.00", "cost_type" => "tokens", "token_type" => "uncached_input_tokens",
          "inference_geo" => "global"
        }]
      }]

      expect(described_class.parse(response).first[:metadata]["pricing_mode"]).to be_nil
    end

    it "accepts Date instances directly when computing the inclusive end date" do
      response[:data] = [{
        "starting_at" => Date.new(2026, 5, 1),
        "ending_at" => Date.new(2026, 5, 2),
        "results" => [{ "amount" => "1.00", "cost_type" => "tokens", "token_type" => "uncached_input_tokens" }]
      }]

      row = described_class.parse(response).first
      expect(row[:period_end]).to eq(Date.new(2026, 5, 1))
    end

    it "accepts epoch timestamps for bucket bounds" do
      response[:data] = [{
        "starting_at" => Time.utc(2026, 5, 1).to_i,
        "ending_at" => Time.utc(2026, 5, 2).to_i,
        "results" => [{ "amount" => "1.00", "cost_type" => "tokens", "token_type" => "uncached_input_tokens" }]
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
