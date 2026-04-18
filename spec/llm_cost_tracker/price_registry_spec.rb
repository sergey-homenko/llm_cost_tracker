# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tempfile"

RSpec.describe LlmCostTracker::PriceRegistry do
  def clear_file_price_cache
    %i[@file_prices @file_prices_cache_key].each do |ivar|
      described_class.remove_instance_variable(ivar) if described_class.instance_variable_defined?(ivar)
    end
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

  describe ".file_prices" do
    it "handles concurrent first-load safely" do
      Tempfile.create(["llm-prices", ".json"]) do |file|
        file.write({ models: { "custom-model" => { input: 1.0, output: 2.0 } } }.to_json)
        file.close

        results = 10.times.map do
          Thread.new { described_class.file_prices(file.path) }
        end.map(&:value)

        expect(results.map(&:object_id).uniq.size).to eq(1)
        expect(results.first).to eq("custom-model" => { input: 1.0, output: 2.0 })
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
              _updated: "2026-04-18",
              _notes: "negotiated rate"
            }
          }
        }.to_json)
        file.close

        output = capture_stderr { described_class.file_prices(file.path) }

        expect(output).to be_empty
      end
    end
  end
end
