# frozen_string_literal: true

require "spec_helper"
require "tempfile"

RSpec.describe LlmCostTracker::Pricing::Registry do
  describe ".file_metadata" do
    it "loads registry metadata from a local prices file" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({
          metadata: { updated_at: "2026-04-22", currency: "USD" },
          models: { "custom-model" => { "input" => 1.0, "output" => 2.0 } }
        }.to_json)
        file.close

        expect(described_class.file_metadata(file.path)).to eq(
          "updated_at" => "2026-04-22",
          "currency" => "USD"
        )
      end
    end

    it "raises a readable error for invalid metadata shapes" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({
          metadata: ["bad"],
          models: { "custom-model" => { "input" => 1.0, "output" => 2.0 } }
        }.to_json)
        file.close

        expect do
          described_class.file_metadata(file.path)
        end.to raise_error(LlmCostTracker::Error, /prices_file metadata must be a hash/)
      end
    end
  end

  describe ".file_prices" do
    it "returns consistent prices under concurrent first-load" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({ models: { "custom-model" => { "input" => 1.0, "output" => 2.0 } } }.to_json)
        file.close

        results = 10.times.map do
          Thread.new { described_class.file_prices(file.path) }
        end.map(&:value)

        expect(results).to all(eq("custom-model" => { "input" => 1.0, "output" => 2.0 }))
      end
    end

    it "warns once per file load when unknown price keys are ignored" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({ models: { "custom-model" => { "input" => 1.0, outpu: 2.0, _input: 2.0 } } }.to_json)
        file.close

        output = capture_log do
          2.times { described_class.file_prices(file.path) }
        end

        expect(output.scan("Unknown price keys").size).to eq(1)
        expect(output).to include('"outpu"')
        expect(output).to include('"_input"')
      end
    end

    it "allows local price metadata keys without warnings" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({
          models: {
            "custom-model" => {
              "input" => 1.0,
              "output" => 2.0,
              _source: "manual"
            }
          }
        }.to_json)
        file.close

        output = capture_log { described_class.file_prices(file.path) }

        expect(output).to be_empty
      end
    end

    it "allows mode-specific price keys without warnings" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({
          models: {
            "custom-model" => {
              "input" => 1.0,
              "output" => 2.0,
              "batch_input" => 0.5,
              "batch_output" => 1.0,
              "_context_price_threshold_tokens" => 200_000,
              "above_context_input" => 2.0,
              "above_context_output" => 3.0,
              "priority_cache_read_input" => 0.25,
              "priority_cache_write_extended_input" => 1.5
            }
          }
        }.to_json)
        file.close

        output = capture_log do
          expect(described_class.file_prices(file.path)).to eq(
            "custom-model" => {
              "input" => 1.0,
              "output" => 2.0,
              "batch_input" => 0.5,
              "batch_output" => 1.0,
              "_context_price_threshold_tokens" => 200_000,
              "above_context_input" => 2.0,
              "above_context_output" => 3.0,
              "priority_cache_read_input" => 0.25,
              "priority_cache_write_extended_input" => 1.5
            }
          )
        end

        expect(output).to be_empty
      end
    end

    it "raises a readable error for invalid price entry shapes" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({ models: { "custom-model" => 1.0 } }.to_json)
        file.close

        expect do
          described_class.file_prices(file.path)
        end.to raise_error(LlmCostTracker::Error, /price entry for "custom-model".*must be a hash/)
      end
    end

    it "rejects negative token rates" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({ models: { "custom-model" => { input: -1.0 } } }.to_json)
        file.close

        expect do
          described_class.file_prices(file.path)
        end.to raise_error(LlmCostTracker::Error, /must be non-negative/)
      end
    end

    it "rejects infinite token rates so an Infinity override cannot poison cost math downstream" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write(%({"models":{"custom-model":{"input":.inf}}}))
        file.close

        expect do
          described_class.file_prices(file.path)
        end.to raise_error(LlmCostTracker::Error, /must be finite/)
      end
    end
  end
end
