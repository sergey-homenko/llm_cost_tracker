# frozen_string_literal: true

require "spec_helper"
require "tempfile"

require_relative "../dummy/config/environment"

RSpec.describe LlmCostTracker::ReconcileTasks do
  include_context "with mounted llm cost tracker engine"
  include_context "with reconciliation enabled"

  describe ".import_from_env" do
    let(:openai_payload) do
      {
        "data" => [{
          "start_time" => Time.utc(2026, 5, 1).to_i,
          "end_time" => Time.utc(2026, 5, 2).to_i,
          "results" => [{
            "amount" => { "value" => 1.5, "currency" => "usd" },
            "line_item" => "gpt-4o tokens",
            "project_id" => "proj_a"
          }]
        }]
      }
    end

    it "parses OpenAI Costs API responses through the source-specific parser" do
      Tempfile.create(["costs", ".json"]) do |file|
        file.write(openai_payload.to_json)
        file.flush

        result = described_class.import_from_env(env: { "SOURCE" => "openai", "INPUT" => file.path })

        expect(result.inserted).to eq(1)
        expect(LlmCostTracker::ProviderInvoice.count).to eq(1)
      end
    end

    it "imports a generic JSON payload with a top-level rows array for unknown sources" do
      Tempfile.create(["rows", ".json"]) do |file|
        file.write({
          "rows" => [{
            "external_id" => "csv-1",
            "period_start" => "2026-05-01",
            "period_end" => "2026-05-31",
            "billed_amount" => "1.00",
            "currency" => "USD"
          }]
        }.to_json)
        file.flush

        result = described_class.import_from_env(env: { "SOURCE" => "csv", "PROVIDER" => "openai",
                                                         "INPUT" => file.path })

        expect(result.inserted).to eq(1)
      end
    end

    it "raises when SOURCE is missing" do
      Tempfile.create(["rows", ".json"]) do |file|
        file.write("{}")
        file.flush

        expect do
          described_class.import_from_env(env: { "INPUT" => file.path })
        end.to raise_error(ArgumentError, /missing SOURCE/)
      end
    end

    it "raises when the INPUT file does not exist" do
      expect do
        described_class.import_from_env(env: { "SOURCE" => "openai", "INPUT" => "/no/such/path.json" })
      end.to raise_error(ArgumentError, /INPUT file not found/)
    end

    it "raises for unknown sources rather than silently falling back to a generic rows reader" do
      Tempfile.create(["rows", ".json"]) do |file|
        file.write({ "rows" => [{ "external_id" => "x" }] }.to_json)
        file.flush

        expect do
          described_class.import_from_env(env: { "SOURCE" => "opnai", "INPUT" => file.path })
        end.to raise_error(ArgumentError, /unknown SOURCE/)
      end
    end
  end

  describe ".diff_from_env" do
    it "runs Reconciliation.diff with parsed period bounds" do
      LlmCostTracker::Reconciliation.import(
        source: :openai,
        rows: [{
          external_id: "row",
          period_start: "2026-05-01",
          period_end: "2026-05-31",
          billed_amount: "10.00",
          currency: "USD",
          metadata: {
            row_type: "cost", meter: "tokens", authority: "cost_api", match_basis: "period_only"
          }
        }]
      )

      diff = described_class.diff_from_env(env: {
        "SOURCE" => "openai",
        "PERIOD_START" => "2026-05-01",
        "PERIOD_END" => "2026-05-31"
      })

      expect(diff.provider_total).to eq(BigDecimal("10.00"))
    end

    it "raises when PERIOD_END is missing" do
      expect do
        described_class.diff_from_env(env: { "SOURCE" => "openai", "PERIOD_START" => "2026-05-01" })
      end.to raise_error(ArgumentError, /missing PERIOD_END/)
    end
  end

  describe ".print_diff" do
    it "masks api_key and workspace ids in attribution lines" do
      diff = LlmCostTracker::Reconciliation::DiffResult.new(
        source: "openai", provider: "openai",
        period_start: Date.new(2026, 5, 1), period_end: Date.new(2026, 5, 31),
        currency: "USD", scope: {}, provider_total: BigDecimal("0"), local_total: BigDecimal("0"),
        local_total_source: :line_items,
        delta_amount: BigDecimal("0"), delta_percent: nil,
        unmatched_provider_rows: [{
          external_id: "openai:phantom",
          billed_amount: BigDecimal("1"),
          attribution: { provider_api_key_id: "sk-live-1234567890ABCDEF" },
          match_basis: "api_key"
        }],
        unmatched_local_calls: [], non_cost_rows: []
      )
      output = StringIO.new

      described_class.print_diff(diff, output: output)

      expect(output.string).to include("provider_api_key_id=***CDEF")
      expect(output.string).not_to include("sk-live-1234567890ABCDEF")
    end

    it "renders a structured human-readable summary" do
      diff = LlmCostTracker::Reconciliation::DiffResult.new(
        source: "openai",
        provider: "openai",
        period_start: Date.new(2026, 5, 1),
        period_end: Date.new(2026, 5, 31),
        currency: "USD",
        scope: {},
        provider_total: BigDecimal("10.00"),
        local_total: BigDecimal("9.00"),
        local_total_source: :line_items,
        delta_amount: BigDecimal("-1.00"),
        delta_percent: -10.0,
        unmatched_provider_rows: [{
          external_id: "openai:phantom",
          billed_amount: BigDecimal("5.00"),
          attribution: { provider_project_id: "proj_x" },
          match_basis: "project"
        }],
        unmatched_local_calls: [{
          attribution: { provider_project_id: "proj_y" },
          count: 2,
          total_cost: BigDecimal("3.00")
        }],
        non_cost_rows: [{
          external_id: "openai:credit",
          row_type: "credit",
          meter: "tokens",
          billed_amount: BigDecimal("-2.00"),
          attribution: { provider_project_id: "proj_x" },
          match_basis: "project"
        }]
      )

      output = StringIO.new
      described_class.print_diff(diff, output: output)

      string = output.string
      expect(string).to include("openai 2026-05-01..2026-05-31")
      expect(string).to include("provider_total: 10.0 USD")
      expect(string).to include("local_total:    9.0 USD")
      expect(string).to include("delta:          -1.0 (-10.0%)")
      expect(string).to include("unmatched provider rows")
      expect(string).to include("unmatched local calls")
      expect(string).to include("non-cost evidence")
    end
  end

  describe ".run_import" do
    let(:input_file) { Tempfile.new(["import", ".json"]) }
    let(:openai_payload) do
      {
        "data" => [{
          "start_time" => Time.utc(2026, 5, 1).to_i,
          "end_time" => Time.utc(2026, 5, 2).to_i,
          "results" => [{
            "amount" => { "value" => 1.5, "currency" => "usd" },
            "line_item" => "gpt-4o tokens"
          }]
        }]
      }
    end

    after { input_file.close! }

    it "prints an import summary line" do
      input_file.write(openai_payload.to_json)
      input_file.flush
      output = StringIO.new

      described_class.run_import(
        env: { "SOURCE" => "openai", "INPUT" => input_file.path },
        output: output,
        error_output: StringIO.new
      )

      expect(output.string).to include("imported 1 rows")
      expect(output.string).to include("inserted=1")
    end

    it "raises after writing errors when the import has any" do
      input_file.write({ "rows" => [{ "external_id" => "x" }] }.to_json)
      input_file.flush
      errors = StringIO.new

      expect do
        described_class.run_import(
          env: { "SOURCE" => "csv", "PROVIDER" => "openai", "INPUT" => input_file.path },
          output: StringIO.new, error_output: errors
        )
      end.to raise_error(/reconcile import had errors/)
      expect(errors.string).to include("error:")
    end
  end

  describe ".run_diff" do
    it "prints a diff summary" do
      LlmCostTracker::Reconciliation.import(
        source: :openai,
        rows: [{
          external_id: "row",
          period_start: "2026-05-01",
          period_end: "2026-05-31",
          billed_amount: "5.00",
          currency: "USD",
          metadata: {
            row_type: "cost", meter: "tokens", authority: "cost_api", match_basis: "period_only"
          }
        }]
      )
      output = StringIO.new

      described_class.run_diff(
        env: { "SOURCE" => "openai", "PERIOD_START" => "2026-05-01", "PERIOD_END" => "2026-05-31" },
        output: output
      )

      expect(output.string).to include("provider_total: 5.0 USD")
    end
  end
end
