# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe LlmCostTracker::Tracker do
  describe ".record" do
    it "emits an ActiveSupport::Notifications event" do
      events = []
      ActiveSupport::Notifications.subscribe(described_class::EVENT_NAME) do |*, payload|
        events << payload
      end

      described_class.record(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 100,
        output_tokens: 50,
        metadata: { feature: "chat", user_id: 42 }
      )

      expect(events.size).to eq(1)
      event = events.first
      expect(event[:provider]).to eq("openai")
      expect(event[:model]).to eq("gpt-4o")
      expect(event[:input_tokens]).to eq(100)
      expect(event[:output_tokens]).to eq(50)
      expect(event[:total_tokens]).to eq(150)
      expect(event[:cost][:total_cost]).to be > 0
      expect(event[:tags]).to include(feature: "chat", user_id: 42)
      expect(event[:tracked_at]).to be_a(Time)
    end

    it "includes latency when provided manually" do
      event = described_class.record(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 100,
        output_tokens: 50,
        latency_ms: 123
      )

      expect(event.latency_ms).to eq(123)
    end

    it "warns and keeps returning the event when storage fails by default" do
      event = nil

      LlmCostTracker.configure do |c|
        c.storage_backend = :custom
        c.custom_storage = ->(_event) { raise "storage down" }
      end

      expect do
        event = described_class.record(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 100,
          output_tokens: 50
        )
      end.to output(/Storage failed; tracking event was not persisted: RuntimeError: storage down/).to_stderr

      expect(event.model).to eq("gpt-4o")
    end

    it "handles custom storage errors that inherit from LlmCostTracker::Error" do
      custom_error = Class.new(LlmCostTracker::Error)
      stub_const("CustomStorageFailure", custom_error)

      LlmCostTracker.configure do |c|
        c.storage_backend = :custom
        c.custom_storage = ->(_event) { raise CustomStorageFailure, "custom failure" }
      end

      expect do
        described_class.record(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 100,
          output_tokens: 50
        )
      end.to output(/Storage failed; tracking event was not persisted: CustomStorageFailure: custom failure/)
        .to_stderr
    end

    it "raises storage errors when configured" do
      LlmCostTracker.configure do |c|
        c.storage_backend = :custom
        c.storage_error_behavior = :raise
        c.custom_storage = ->(_event) { raise "storage down" }
      end

      expect do
        described_class.record(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 100,
          output_tokens: 50
        )
      end.to raise_error(LlmCostTracker::StorageError) { |error|
        expect(error.original_error.message).to eq("storage down")
      }
    end

    it "rejects unknown storage behavior values" do
      expect do
        LlmCostTracker.configure { |c| c.storage_error_behavior = :explode }
      end.to raise_error(LlmCostTracker::Error, /Unknown storage_error_behavior/)
    end

    it "rejects unknown storage backends at configuration time" do
      expect do
        LlmCostTracker.configure { |c| c.storage_backend = :somewhere_else }
      end.to raise_error(LlmCostTracker::Error, /Unknown storage_backend/)
    end

    it "honors a false custom storage return by skipping budget checks" do
      budget_data = nil

      LlmCostTracker.configure do |c|
        c.storage_backend = :custom
        c.custom_storage = ->(_event) { false }
        c.monthly_budget = 0.0001
        c.on_budget_exceeded = ->(data) { budget_data = data }
      end

      described_class.record(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(budget_data).to be_nil
    end

    it "merges default_tags with metadata" do
      LlmCostTracker.configure do |c|
        c.default_tags = { environment: "test", app: "my_app" }
      end

      events = []
      ActiveSupport::Notifications.subscribe(described_class::EVENT_NAME) do |*, payload|
        events << payload
      end

      described_class.record(
        provider: "anthropic",
        model: "claude-sonnet-4-6",
        input_tokens: 200,
        output_tokens: 80,
        metadata: { feature: "summarize" }
      )

      tags = events.first[:tags]
      expect(tags[:environment]).to eq("test")
      expect(tags[:app]).to eq("my_app")
      expect(tags[:feature]).to eq("summarize")
    end

    it "evaluates callable default tags for each event" do
      value = "first"
      LlmCostTracker.configure do |c|
        c.default_tags = -> { { request_id: value } }
      end

      first = described_class.record(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 1,
        output_tokens: 1
      )
      value = "second"
      second = described_class.record(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 1,
        output_tokens: 1
      )

      expect(first.tags).to include(request_id: "first")
      expect(second.tags).to include(request_id: "second")
    end

    it "merges scoped tags between default tags and explicit metadata" do
      LlmCostTracker.configure do |c|
        c.default_tags = { env: "test", feature: "default" }
      end

      event = LlmCostTracker.with_tags(feature: "chat", request_id: "req_123") do
        described_class.record(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 1,
          output_tokens: 1,
          metadata: { feature: "summary", user_id: 42 }
        )
      end

      expect(event.tags).to eq(env: "test", feature: "summary", request_id: "req_123", user_id: 42)
    end

    it "uses unknown when manual tracking has no model" do
      event = described_class.record(
        provider: "custom",
        model: nil,
        input_tokens: 1,
        output_tokens: 1
      )

      expect(event.model).to eq("unknown")
      expect(event.cost).to be_nil
    end

    it "restores scoped tags after the block" do
      inside = LlmCostTracker.with_tags(request_id: "req_123") do
        described_class.record(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 1,
          output_tokens: 1
        )
      end
      outside = described_class.record(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 1,
        output_tokens: 1
      )

      expect(inside.tags).to include(request_id: "req_123")
      expect(outside.tags).not_to include(:request_id)
    end

    it "keeps internal usage metadata out of tags" do
      event = described_class.record(
        provider: "anthropic",
        model: "claude-sonnet-4-6",
        input_tokens: 100,
        output_tokens: 50,
        metadata: {
          feature: "summarize",
          cache_read_input_tokens: 25,
          cache_write_input_tokens: 10,
          hidden_output_tokens: 5
        }
      )

      expect(event.total_tokens).to eq(185)
      expect(event.tags).to eq(feature: "summarize")
    end

    it "uses pricing_mode without storing it as a tag" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "batchable-model" => {
            input: 1.0,
            output: 2.0,
            batch_input: 0.5,
            batch_output: 1.0
          }
        }
      end

      event = described_class.record(
        provider: "custom",
        model: "batchable-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        pricing_mode: :batch,
        metadata: { feature: "bulk" }
      )

      expect(event.pricing_mode).to eq("batch")
      expect(event.cost.total_cost).to eq(1.5)
      expect(event.tags).to eq(feature: "bulk")
    end

    it "accepts pricing_mode from internal metadata" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "metadata-mode-model" => {
            input: 1.0,
            output: 2.0,
            batch_input: 0.5,
            batch_output: 1.0
          }
        }
      end

      event = described_class.record(
        provider: "custom",
        model: "metadata-mode-model",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        metadata: { pricing_mode: :batch, feature: "bulk" }
      )

      expect(event.pricing_mode).to eq("batch")
      expect(event.cost.total_cost).to eq(1.5)
      expect(event.tags).to eq(feature: "bulk")
    end

    it "triggers budget callback when exceeded" do
      budget_data = nil

      LlmCostTracker.configure do |c|
        c.monthly_budget = 0.0001 # very small budget
        c.on_budget_exceeded = ->(data) { budget_data = data }
      end

      described_class.record(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 1_000_000,
        output_tokens: 1_000_000
      )

      expect(budget_data).not_to be_nil
      expect(budget_data[:monthly_total]).to be > 0
    end

    it "triggers per-call budget callback when one event exceeds the ceiling" do
      budget_data = nil

      LlmCostTracker.configure do |c|
        c.per_call_budget = 0.0001
        c.on_budget_exceeded = ->(data) { budget_data = data }
      end

      event = described_class.record(
        provider: "openai",
        model: "gpt-4o",
        input_tokens: 1_000_000,
        output_tokens: 0
      )

      expect(budget_data).to include(
        budget_type: :per_call,
        call_cost: event.cost.total_cost,
        total: event.cost.total_cost,
        budget: 0.0001,
        last_event: event
      )
    end

    it "raises a budget error when configured to raise" do
      LlmCostTracker.configure do |c|
        c.monthly_budget = 0.0001
        c.budget_exceeded_behavior = :raise
      end

      expect do
        described_class.record(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 1_000_000,
          output_tokens: 1_000_000
        )
      end.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
        expect(error.monthly_total).to be > error.budget
        expect(error.last_event.provider).to eq("openai")
      }
    end

    it "raises a per-call budget error when configured to raise" do
      LlmCostTracker.configure do |c|
        c.per_call_budget = 0.0001
        c.budget_exceeded_behavior = :raise
      end

      expect do
        described_class.record(
          provider: "openai",
          model: "gpt-4o",
          input_tokens: 1_000_000,
          output_tokens: 0
        )
      end.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
        expect(error.budget_type).to eq(:per_call)
        expect(error.call_cost).to eq(error.total)
        expect(error.monthly_total).to be_nil
        expect(error.budget).to eq(0.0001)
      }
    end

    it "rejects unknown budget behavior values" do
      expect do
        LlmCostTracker.configure { |c| c.budget_exceeded_behavior = :explode }
      end.to raise_error(LlmCostTracker::Error, /Unknown budget_exceeded_behavior/)
    end

    it "warns when block_requests is configured without ActiveRecord storage" do
      expect do
        LlmCostTracker.configure do |c|
          c.storage_backend = :log
          c.budget_exceeded_behavior = :block_requests
        end
      end.to output(/:block_requests requires storage_backend = :active_record/).to_stderr
    end

    it "warns by default when model pricing is unknown" do
      event = nil

      LlmCostTracker.configure do |c|
        c.storage_backend = :custom
        c.custom_storage = ->(_event) {}
      end

      expect do
        event = described_class.record(
          provider: "openai",
          model: "unknown-chat-model",
          input_tokens: 100,
          output_tokens: 50
        )
      end.to output(/No pricing configured for model "unknown-chat-model"/).to_stderr

      expect(event.cost).to be_nil
    end

    it "warns once per unknown model" do
      LlmCostTracker.configure do |c|
        c.storage_backend = :custom
        c.custom_storage = ->(_event) {}
      end

      original_stderr = $stderr
      fake_stderr = StringIO.new
      $stderr = fake_stderr

      begin
        2.times do
          described_class.record(
            provider: "openai",
            model: "unknown-model-dedup",
            input_tokens: 100,
            output_tokens: 50
          )
        end
      ensure
        $stderr = original_stderr
      end

      expect(fake_stderr.string.scan('No pricing configured for model "unknown-model-dedup"').size).to eq(1)
    end

    it "raises unknown pricing errors when configured" do
      LlmCostTracker.configure do |c|
        c.storage_backend = :custom
        c.custom_storage = ->(_event) {}
        c.unknown_pricing_behavior = :raise
      end

      expect do
        described_class.record(
          provider: "openai",
          model: "unknown-chat-model",
          input_tokens: 100,
          output_tokens: 50
        )
      end.to raise_error(LlmCostTracker::UnknownPricingError) { |error|
        expect(error.model).to eq("unknown-chat-model")
      }
    end

    it "rejects unknown pricing behavior values" do
      expect do
        LlmCostTracker.configure { |c| c.unknown_pricing_behavior = :explode }
      end.to raise_error(LlmCostTracker::Error, /Unknown unknown_pricing_behavior/)
    end
  end
end
