# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe LlmCostTracker::Tracker do
  describe ".record" do
    before { allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true) }

    def token_usage(input_tokens:, output_tokens:, **metadata)
      metadata = metadata.to_h.symbolize_keys
      LlmCostTracker::TokenUsage.build(
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: metadata[:total_tokens],
        cache_read_input_tokens: metadata[:cache_read_input_tokens],
        cache_write_input_tokens: metadata[:cache_write_input_tokens],
        cache_write_1h_input_tokens: metadata[:cache_write_1h_input_tokens],
        hidden_output_tokens: metadata[:hidden_output_tokens]
      )
    end

    def record(provider:, model:, token_usage:, stream: false, usage_source: nil, provider_response_id: nil, **options)
      described_class.record(
        capture: LlmCostTracker::UsageCapture.build(
          provider: provider,
          model: model,
          token_usage: token_usage,
          stream: stream,
          usage_source: usage_source,
          provider_response_id: provider_response_id
        ),
        **options
      )
    end

    it "emits an ActiveSupport::Notifications event" do
      events = []
      ActiveSupport::Notifications.subscribe(described_class::EVENT_NAME) do |*, payload|
        events << payload
      end

      record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: token_usage(input_tokens: 100, output_tokens: 50),
        metadata: { feature: "chat", user_id: 42 }
      )

      expect(events.size).to eq(1)
      event = events.first
      expect(event[:provider]).to eq("openai")
      expect(event[:model]).to eq("gpt-4o")
      expect(event.dig(:token_usage, :input_tokens)).to eq(100)
      expect(event.dig(:token_usage, :output_tokens)).to eq(50)
      expect(event.dig(:token_usage, :total_tokens)).to eq(150)
      expect(event[:cost][:total_cost]).to be > 0
      expect(event[:tags]).to include(feature: "chat", user_id: 42)
      expect(event[:tracked_at]).to be_a(Time)
    end

    it "includes latency when provided manually" do
      event = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: token_usage(input_tokens: 100, output_tokens: 50),
        latency_ms: 123
      )

      expect(event.latency_ms).to eq(123)
    end

    it "raises storage errors from the ActiveRecord backend" do
      allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_raise("storage down")

      expect do
        record(
          provider: "openai",
          model: "gpt-4o",
          token_usage: token_usage(input_tokens: 100, output_tokens: 50)
        )
      end.to raise_error(RuntimeError, "storage down")
    end

    it "merges default_tags with metadata" do
      LlmCostTracker.configure do |c|
        c.default_tags = { environment: "test", app: "my_app" }
      end

      events = []
      ActiveSupport::Notifications.subscribe(described_class::EVENT_NAME) do |*, payload|
        events << payload
      end

      record(
        provider: "anthropic",
        model: "claude-sonnet-4-6",
        token_usage: token_usage(input_tokens: 200, output_tokens: 80),
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

      first = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: token_usage(input_tokens: 1, output_tokens: 1)
      )
      value = "second"
      second = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: token_usage(input_tokens: 1, output_tokens: 1)
      )

      expect(first.tags).to include(request_id: "first")
      expect(second.tags).to include(request_id: "second")
    end

    it "merges scoped tags between default tags and explicit metadata" do
      LlmCostTracker.configure do |c|
        c.default_tags = { env: "test", feature: "default" }
      end

      event = LlmCostTracker.with_tags(feature: "chat", request_id: "req_123") do
        record(
          provider: "openai",
          model: "gpt-4o",
          token_usage: token_usage(input_tokens: 1, output_tokens: 1),
          metadata: { feature: "summary", user_id: 42 }
        )
      end

      expect(event.tags).to eq(env: "test", feature: "summary", request_id: "req_123", user_id: 42)
    end

    it "uses unknown when manual tracking has no model" do
      event = record(
        provider: "custom",
        model: nil,
        token_usage: token_usage(input_tokens: 1, output_tokens: 1)
      )

      expect(event.model).to eq("unknown")
      expect(event.cost).to be_nil
    end

    it "restores scoped tags after the block" do
      inside = LlmCostTracker.with_tags(request_id: "req_123") do
        record(
          provider: "openai",
          model: "gpt-4o",
          token_usage: token_usage(input_tokens: 1, output_tokens: 1)
        )
      end
      outside = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: token_usage(input_tokens: 1, output_tokens: 1)
      )

      expect(inside.tags).to include(request_id: "req_123")
      expect(outside.tags).not_to include(:request_id)
    end

    it "keeps internal usage metadata out of tags" do
      usage_metadata = {
        cache_read_input_tokens: 25,
        cache_write_input_tokens: 10,
        hidden_output_tokens: 5
      }

      event = record(
        provider: "anthropic",
        model: "claude-sonnet-4-6",
        token_usage: token_usage(input_tokens: 100, output_tokens: 50, **usage_metadata),
        metadata: usage_metadata.merge(feature: "summarize")
      )

      expect(event.token_usage.total_tokens).to eq(185)
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

      event = record(
        provider: "custom",
        model: "batchable-model",
        token_usage: token_usage(input_tokens: 1_000_000, output_tokens: 1_000_000),
        pricing_mode: :batch,
        metadata: { feature: "bulk" }
      )

      expect(event.pricing_mode).to eq("batch")
      expect(event.total_cost).to eq(1.5)
      expect(event.tags).to eq(feature: "bulk")
    end

    it "keeps pricing_mode metadata out of tags" do
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

      event = record(
        provider: "custom",
        model: "metadata-mode-model",
        token_usage: token_usage(input_tokens: 1_000_000, output_tokens: 1_000_000),
        metadata: { pricing_mode: :batch, feature: "bulk" }
      )

      expect(event.pricing_mode).to be_nil
      expect(event.total_cost).to eq(3.0)
      expect(event.tags).to eq(feature: "bulk")
    end

    it "triggers budget callback when exceeded" do
      budget_data = nil

      LlmCostTracker.configure do |c|
        c.monthly_budget = 0.0001
        c.on_budget_exceeded = ->(data) { budget_data = data }
      end
      allow(LlmCostTracker::Ledger::PeriodTotals).to receive(:call).and_return(monthly: 12.5)

      record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: token_usage(input_tokens: 1_000_000, output_tokens: 1_000_000)
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

      event = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: token_usage(input_tokens: 1_000_000, output_tokens: 0)
      )

      expect(budget_data).to include(
        budget_type: :per_call,
        call_cost: event.total_cost,
        total: event.total_cost,
        budget: 0.0001,
        last_event: event
      )
    end

    it "raises a budget error when configured to raise" do
      LlmCostTracker.configure do |c|
        c.monthly_budget = 0.0001
        c.budget_exceeded_behavior = :raise
      end
      allow(LlmCostTracker::Ledger::PeriodTotals).to receive(:call).and_return(monthly: 12.5)

      expect do
        record(
          provider: "openai",
          model: "gpt-4o",
          token_usage: token_usage(input_tokens: 1_000_000, output_tokens: 1_000_000)
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
        record(
          provider: "openai",
          model: "gpt-4o",
          token_usage: token_usage(input_tokens: 1_000_000, output_tokens: 0)
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

    it "warns by default when model pricing is unknown" do
      event = nil

      expect do
        event = record(
          provider: "openai",
          model: "unknown-chat-model",
          token_usage: token_usage(input_tokens: 100, output_tokens: 50)
        )
      end.to output(/No pricing configured for model "unknown-chat-model"/).to_stderr

      expect(event.cost).to be_nil
    end

    it "warns once per unknown model" do
      original_stderr = $stderr
      fake_stderr = StringIO.new
      $stderr = fake_stderr

      begin
        2.times do
          record(
            provider: "openai",
            model: "unknown-model-dedup",
            token_usage: token_usage(input_tokens: 100, output_tokens: 50)
          )
        end
      ensure
        $stderr = original_stderr
      end

      expect(fake_stderr.string.scan('No pricing configured for model "unknown-model-dedup"').size).to eq(1)
    end

    it "raises unknown pricing errors when configured" do
      LlmCostTracker.configure do |c|
        c.unknown_pricing_behavior = :raise
      end

      expect do
        record(
          provider: "openai",
          model: "unknown-chat-model",
          token_usage: token_usage(input_tokens: 100, output_tokens: 50)
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
