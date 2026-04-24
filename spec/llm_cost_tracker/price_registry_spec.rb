# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tempfile"

RSpec.describe LlmCostTracker::PriceRegistry do
  def clear_file_price_cache
    return unless described_class.instance_variable_defined?(:@file_prices_cache)

    described_class.remove_instance_variable(:@file_prices_cache)
  end

  def capture_stderr
    original_stderr = $stderr
    fake_stderr = StringIO.new
    $stderr = fake_stderr
    yield
    fake_stderr.string
  ensure
    $stderr = original_stderr
  end

  before do
    clear_file_price_cache
  end

  describe ".file_metadata" do
    it "loads registry metadata from a local prices file" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({
          metadata: { updated_at: "2026-04-22", currency: "USD" },
          models: { "custom-model" => { input: 1.0, output: 2.0 } }
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
          models: { "custom-model" => { input: 1.0, output: 2.0 } }
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
        file.write({ models: { "custom-model" => { input: 1.0, output: 2.0 } } }.to_json)
        file.close

        results = 10.times.map do
          Thread.new { described_class.file_prices(file.path) }
        end.map(&:value)

        expect(results).to all(eq("custom-model" => { input: 1.0, output: 2.0 }))
      end
    end

    it "warns once per file load when unknown price keys are ignored" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({ models: { "custom-model" => { input: 1.0, outpu: 2.0 } } }.to_json)
        file.close

        output = capture_stderr do
          2.times { described_class.file_prices(file.path) }
        end

        expect(output.scan("Unknown price keys").size).to eq(1)
        expect(output).to include('"outpu"')
      end
    end

    it "allows local price metadata keys without warnings" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({
          models: {
            "custom-model" => {
              input: 1.0,
              output: 2.0,
              _source: "contract",
              _source_version: "snapshot-v1",
              _fetched_at: "2026-04-22T00:00:00Z",
              _updated: "2026-04-18",
              _notes: "negotiated rate",
              _validator_override: ["skip_relative_change"]
            }
          }
        }.to_json)
        file.close

        output = capture_stderr { described_class.file_prices(file.path) }

        expect(output).to be_empty
      end
    end

    it "allows mode-specific price keys without warnings" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({
          models: {
            "custom-model" => {
              input: 1.0,
              output: 2.0,
              batch_input: 0.5,
              batch_output: 1.0,
              priority_cache_read_input: 0.25
            }
          }
        }.to_json)
        file.close

        output = capture_stderr do
          expect(described_class.file_prices(file.path)).to eq(
            "custom-model" => {
              input: 1.0,
              output: 2.0,
              batch_input: 0.5,
              batch_output: 1.0,
              priority_cache_read_input: 0.25
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
  end
end
