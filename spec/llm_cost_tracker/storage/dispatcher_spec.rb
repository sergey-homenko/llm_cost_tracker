# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Storage::Dispatcher do
  let(:cost) do
    LlmCostTracker::Cost.new(
      input_cost: 0.0001,
      cache_read_input_cost: 0.0,
      cache_write_input_cost: 0.0,
      output_cost: 0.0002,
      total_cost: 0.0003,
      currency: "USD"
    )
  end

  let(:event) do
    LlmCostTracker::Event.new(
      provider: "openai",
      model: "gpt-4o",
      input_tokens: 10,
      output_tokens: 20,
      total_tokens: 30,
      cache_read_input_tokens: 0,
      cache_write_input_tokens: 0,
      hidden_output_tokens: 0,
      pricing_mode: nil,
      cost: cost,
      tags: {},
      latency_ms: nil,
      stream: false,
      usage_source: nil,
      provider_response_id: nil,
      tracked_at: Time.utc(2026, 4, 27)
    )
  end

  describe ".save" do
    it "returns the event when custom storage is unset" do
      LlmCostTracker.configure { |config| config.storage_backend = :custom }

      expect(described_class.save(event)).to eq(event)
    end

    it "logs events with unknown cost" do
      LlmCostTracker.configure { |config| config.storage_backend = :log }

      expect do
        described_class.save(event.with(cost: nil))
      end.to output(%r{openai/gpt-4o tokens=30 cost=unknown}).to_stderr
    end

    it "returns false without warning when storage errors are ignored" do
      LlmCostTracker.configure do |config|
        config.storage_backend = :custom
        config.storage_error_behavior = :ignore
        config.custom_storage = ->(_event) { raise "storage down" }
      end

      result = nil
      expect { result = described_class.save(event) }.not_to output.to_stderr
      expect(result).to be(false)
    end

    it "raises storage errors when configured" do
      LlmCostTracker.configure do |config|
        config.storage_backend = :custom
        config.storage_error_behavior = :raise
        config.custom_storage = ->(_event) { raise "storage down" }
      end

      expect { described_class.save(event) }.to raise_error(LlmCostTracker::StorageError) { |error|
        expect(error.original_error.message).to eq("storage down")
      }
    end

    it "does not wrap budget errors from storage" do
      error = LlmCostTracker::BudgetExceededError.new(budget: 1.0, total: 2.0)
      LlmCostTracker.configure do |config|
        config.storage_backend = :custom
        config.custom_storage = ->(_event) { raise error }
      end

      expect { described_class.save(event) }.to raise_error(error)
    end

    it "wraps ActiveRecord store load failures through storage error handling" do
      hide_const("LlmCostTracker::Storage::ActiveRecordStore")
      allow(described_class).to receive(:require_relative).and_call_original
      allow(described_class)
        .to receive(:require_relative)
        .with("active_record_store")
        .and_raise(LoadError, "missing active_record")
      LlmCostTracker.configure do |config|
        config.storage_backend = :active_record
        config.storage_error_behavior = :raise
      end

      expect { described_class.save(event) }.to raise_error(LlmCostTracker::StorageError) { |error|
        expect(error.original_error.message).to include("ActiveRecord storage requires")
      }
    end
  end
end
