# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Storage::Writer do
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
      event_id: "evt_test",
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

  it "writes through the ActiveRecord backend" do
    allow(LlmCostTracker::Storage::ActiveRecordBackend).to receive(:save).with(event).and_return(event)

    expect(described_class.save(event)).to eq(event)
  end

  it "returns false without warning when write errors are ignored" do
    allow(LlmCostTracker::Storage::ActiveRecordBackend).to receive(:save).and_raise("storage down")
    LlmCostTracker.configure { |config| config.storage_error_behavior = :ignore }

    result = nil
    expect { result = described_class.save(event) }.not_to output.to_stderr
    expect(result).to be(false)
  end

  it "raises storage errors when configured" do
    allow(LlmCostTracker::Storage::ActiveRecordBackend).to receive(:save).and_raise("storage down")
    LlmCostTracker.configure { |config| config.storage_error_behavior = :raise }

    expect { described_class.save(event) }.to raise_error(LlmCostTracker::StorageError) { |error|
      expect(error.original_error.message).to eq("storage down")
    }
  end

  it "does not wrap budget errors from storage" do
    error = LlmCostTracker::BudgetExceededError.new(budget: 1.0, total: 2.0)
    allow(LlmCostTracker::Storage::ActiveRecordBackend).to receive(:save).and_raise(error)

    expect { described_class.save(event) }.to raise_error(error)
  end
end
