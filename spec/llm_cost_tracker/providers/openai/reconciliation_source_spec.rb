# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe LlmCostTracker::Providers::Openai::ReconciliationSource do
  let(:bucket_start) { Time.utc(2026, 5, 1).to_i }
  let(:bucket_end) { Time.utc(2026, 5, 2).to_i }

  let(:response) do
    {
      "object" => "page",
      "data" => [
        {
          "object" => "bucket",
          "start_time" => bucket_start,
          "end_time" => bucket_end,
          "results" => [
            {
              "object" => "organization.costs.result",
              "amount" => { "value" => 1.25, "currency" => "usd" },
              "line_item" => "gpt-4o tokens",
              "project_id" => "proj_alpha",
              "api_key_id" => "key_a"
            },
            {
              "object" => "organization.costs.result",
              "amount" => { "value" => 0.05, "currency" => "usd" },
              "line_item" => "Code Interpreter",
              "project_id" => "proj_alpha"
            }
          ]
        }
      ],
      "has_more" => false
    }
  end

  describe ".parse" do
    it "produces an importable row per bucket result" do
      rows = described_class.parse(response)

      expect(rows.size).to eq(2)
      expect(rows.first).to include(
        period_start: Date.new(2026, 5, 1),
        period_end: Date.new(2026, 5, 1),
        billed_amount: 1.25,
        currency: "USD"
      )
      expect(rows.first[:metadata]).to include(
        "row_type" => "cost",
        "meter" => "tokens",
        "authority" => "cost_api",
        "match_basis" => "project",
        "line_item" => "gpt-4o tokens",
        "provider_project_id" => "proj_alpha",
        "provider_api_key_id" => "key_a"
      )
      expect(rows.first[:external_id]).to start_with("cost-")
    end

    it "tags tool meters from the line item description" do
      response[:data] = [{
        "start_time" => bucket_start,
        "end_time" => bucket_end,
        "results" => [
          { "amount" => { "value" => 0.5, "currency" => "usd" }, "line_item" => "Web Search calls" },
          { "amount" => { "value" => 0.1, "currency" => "usd" }, "line_item" => "Code Interpreter sessions" },
          { "amount" => { "value" => 0.2, "currency" => "usd" }, "line_item" => "File Search storage" }
        ]
      }]

      meters = described_class.parse(response).map { |row| row[:metadata]["meter"] }
      expect(meters).to eq(%w[web_search container_session file_search_storage])
    end

    it "labels rows as the requested row_type and authority" do
      rows = described_class.parse(response, row_type: "usage", authority: "usage_api")

      expect(rows.first[:metadata]["row_type"]).to eq("usage")
      expect(rows.first[:metadata]["authority"]).to eq("usage_api")
    end

    it "falls back to period_only match basis when no attribution is supplied" do
      response[:data] = [{
        "start_time" => bucket_start,
        "end_time" => bucket_end,
        "results" => [{ "amount" => { "value" => 1.0, "currency" => "usd" }, "line_item" => "tokens" }]
      }]

      expect(described_class.parse(response).first[:metadata]["match_basis"]).to eq("period_only")
    end

    it "produces stable external_ids so re-parsing the same response is idempotent" do
      rows_a = described_class.parse(response)
      rows_b = described_class.parse(response)

      expect(rows_a.map { |row| row[:external_id] }).to eq(rows_b.map { |row| row[:external_id] })
      expect(rows_a.first[:external_id]).not_to eq(rows_a.last[:external_id])
    end

    it "differentiates rows that share a line item across different projects" do
      response[:data] = [{
        "start_time" => bucket_start,
        "end_time" => bucket_end,
        "results" => [
          { "amount" => { "value" => 1.0, "currency" => "usd" },
            "line_item" => "gpt-4o tokens", "project_id" => "proj_a" },
          { "amount" => { "value" => 2.0, "currency" => "usd" },
            "line_item" => "gpt-4o tokens", "project_id" => "proj_b" }
        ]
      }]

      rows = described_class.parse(response)

      expect(rows.map { |row| row[:external_id] }.uniq.size).to eq(2)
    end

    it "collapses an hourly bucket into the correct inclusive end date" do
      response[:data] = [{
        "start_time" => Time.utc(2026, 5, 1, 0).to_i,
        "end_time" => Time.utc(2026, 5, 1, 1).to_i,
        "results" => [{ "amount" => { "value" => 0.1, "currency" => "usd" }, "line_item" => "tokens" }]
      }]

      row = described_class.parse(response).first
      expect(row[:period_start]).to eq(Date.new(2026, 5, 1))
      expect(row[:period_end]).to eq(Date.new(2026, 5, 1))
    end

    it "produces consistent fingerprints across epoch and ISO timestamp shapes" do
      iso_response = {
        "data" => [{
          "start_time" => bucket_start, "end_time" => bucket_end,
          "results" => [{ "amount" => { "value" => 1.0, "currency" => "usd" }, "line_item" => "tokens" }]
        }]
      }
      string_response = {
        "data" => [{
          "start_time" => Time.at(bucket_start).utc.iso8601,
          "end_time" => Time.at(bucket_end).utc.iso8601,
          "results" => [{ "amount" => { "value" => 1.0, "currency" => "usd" }, "line_item" => "tokens" }]
        }]
      }

      expect(described_class.parse(iso_response).first[:external_id])
        .to eq(described_class.parse(string_response).first[:external_id])
    end

    it "drops the bucket when a timestamp cannot be parsed" do
      response[:data] = [{
        "start_time" => "garbage",
        "end_time" => "garbage",
        "results" => [{ "amount" => { "value" => 1.0, "currency" => "usd" }, "line_item" => "tokens" }]
      }]

      expect(described_class.parse(response)).to eq([])
    end

    it "skips bucket results without a billed amount" do
      response[:data] = [{
        "start_time" => bucket_start,
        "end_time" => bucket_end,
        "results" => [
          { "amount" => { "currency" => "usd" }, "line_item" => "Web Search" },
          { "amount" => { "value" => 0.5, "currency" => "usd" }, "line_item" => "Web Search" }
        ]
      }]

      rows = described_class.parse(response)

      expect(rows.size).to eq(1)
      expect(rows.first[:billed_amount]).to eq(0.5)
    end

    it "skips buckets without start_time and end_time" do
      response[:data] = [{
        "results" => [{ "amount" => { "value" => 1.0, "currency" => "usd" } }]
      }]

      expect(described_class.parse(response)).to be_empty
    end

    it "accepts the response as a JSON string" do
      rows = described_class.parse(response.to_json)

      expect(rows.size).to eq(2)
    end

    it "raises a parse error rather than silently dropping malformed JSON" do
      expect { described_class.parse("{ not-json") }
        .to raise_error(ArgumentError, /Unable to parse OpenAI Costs payload/)
    end

    it "raises when the JSON payload is not an object" do
      expect { described_class.parse("[1, 2]") }
        .to raise_error(ArgumentError, /must be a JSON object/)
    end

    it "is empty for nil input" do
      expect(described_class.parse(nil)).to eq([])
    end

    it "produces rows in the shape Reconciliation.import expects" do
      rows = described_class.parse(response)

      rows.each do |row|
        expect(row.keys).to include(:external_id, :period_start, :period_end, :billed_amount, :currency, :metadata)
        expect(row[:period_start]).to be_a(Date)
        expect(row[:period_end]).to be_a(Date)
        expect(row[:billed_amount]).to be_a(Numeric)
        expect(row[:currency]).to be_a(String)
        expect(row[:metadata]).to be_a(Hash)
      end
    end
  end
end
