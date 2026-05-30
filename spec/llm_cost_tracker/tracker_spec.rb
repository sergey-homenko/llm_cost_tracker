# frozen_string_literal: true

require "spec_helper"

RSpec.describe LlmCostTracker::Tracker do
  describe ".record" do
    before do
      allow(LlmCostTracker::Ingestion::Inbox).to receive(:save).and_return(true)
      allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_return(true)
    end

    def record(provider:, model:, token_usage:, stream: false, usage_source: nil, provider_response_id: nil,
               provider_project_id: nil, provider_api_key_id: nil, provider_workspace_id: nil,
               capture_pricing_mode: nil, service_line_items: [], **options)
      described_class.record(
        event: LlmCostTracker::Event.build(
          provider: provider,
          model: model,
          token_usage: token_usage,
          stream: stream,
          usage_source: usage_source,
          provider_response_id: provider_response_id,
          provider_project_id: provider_project_id,
          provider_api_key_id: provider_api_key_id,
          provider_workspace_id: provider_workspace_id,
          pricing_mode: capture_pricing_mode,
          service_line_items: service_line_items
        ),
        **options
      )
    end

    it "skips ActiveSupport::Notifications.instrument when no subscriber is listening" do
      ActiveSupport::Notifications.unsubscribe(described_class::EVENT_NAME)
      expect(ActiveSupport::Notifications).not_to receive(:instrument)

      record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50)
      )
    end

    it "saves the event to the inbox even when a subscriber raises" do
      allow(LlmCostTracker::Logging).to receive(:warn)
      ActiveSupport::Notifications.subscribe(described_class::EVENT_NAME) do |*, _payload|
        raise "subscriber boom"
      end

      expect(LlmCostTracker::Ledger::Store).to receive(:insert).once

      expect do
        record(
          provider: "openai",
          model: "gpt-4o",
          token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50)
        )
      end.not_to raise_error

      expect(LlmCostTracker::Logging).to have_received(:warn).with(/Subscriber raised on llm_request/)
    end

    it "drops service line items in a different currency from the header total and warns" do
      allow(LlmCostTracker::Logging).to receive(:warn)
      euro_line = LlmCostTracker::Billing::LineItem.build(
        kind: "web_search_request",
        direction: :service,
        modality: :request,
        unit: :request,
        quantity: 5,
        cost: BigDecimal("0.50"),
        currency: "EUR",
        cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
        component_key: "web_search_request"
      )

      event = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50),
        service_line_items: [euro_line]
      )

      expect(LlmCostTracker::Logging).to have_received(:warn).with(/currency mismatch.*EUR/)
      expect(event.cost.currency).to eq("USD")
      expect(event.total_cost).to be > 0
      expect(event.total_cost).to be < 0.50
    end

    it "sums service line items into the header total when currency matches" do
      usd_line = LlmCostTracker::Billing::LineItem.build(
        kind: "web_search_request",
        direction: :service,
        modality: :request,
        unit: :request,
        quantity: 3,
        cost: BigDecimal("0.30"),
        currency: "USD",
        cost_status: LlmCostTracker::Billing::CostStatus::COMPLETE,
        component_key: "web_search_request"
      )

      event = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50),
        service_line_items: [usd_line]
      )

      expect(event.total_cost).to be >= 0.30
    end

    it "emits an ActiveSupport::Notifications event" do
      events = []
      ActiveSupport::Notifications.subscribe(described_class::EVENT_NAME) do |*, payload|
        events << payload
      end

      record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50),
        provider_project_id: "proj_notify",
        provider_api_key_id: "key_notify",
        provider_workspace_id: "workspace_notify",
        capture_pricing_mode: "batch",
        metadata: { feature: "chat", user_id: 42 }
      )

      expect(events.size).to eq(1)
      event = events.first
      expect(event[:provider]).to eq("openai")
      expect(event[:model]).to eq("gpt-4o")
      expect(event.dig(:token_usage, :input_tokens)).to eq(100)
      expect(event.dig(:token_usage, :output_tokens)).to eq(50)
      expect(event.dig(:token_usage, :total_tokens)).to eq(150)
      expect(BigDecimal(event[:cost][:total])).to be > 0
      expect(event[:cost_status]).to eq(LlmCostTracker::Billing::CostStatus::COMPLETE)
      expect(event[:provider_project_id]).to eq("proj_notify")
      expect(event[:provider_api_key_id]).to eq("key_notify")
      expect(event[:provider_workspace_id]).to eq("workspace_notify")
      expect(event[:pricing_mode]).to eq("batch")
      expect(event.dig(:pricing_snapshot, "rates", "input", "quantity")).to eq(1_000_000)
      expect(event[:tags]).to include(feature: "chat", user_id: 42)
      expect(event[:tracked_at]).to be_a(Time)
    end

    it "includes latency when provided manually" do
      event = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50),
        latency_ms: 123
      )

      expect(event.latency_ms).to eq(123)
    end

    it "drops non-finite latency to avoid integer overflow" do
      event = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1),
        latency_ms: Float::INFINITY
      )

      expect(event.latency_ms).to be_nil
    end

    it "drops non-numeric latency" do
      event = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1),
        latency_ms: "fast"
      )

      expect(event.latency_ms).to be_nil
    end

    it "clamps latency above the 32-bit signed integer ceiling" do
      event = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1),
        latency_ms: (1 << 40)
      )

      expect(event.latency_ms).to eq((1 << 31) - 1)
    end

    it "raises storage errors from the ActiveRecord backend" do
      allow(LlmCostTracker::Ledger::Store).to receive(:insert).and_raise("storage down")

      expect do
        record(
          provider: "openai",
          model: "gpt-4o",
          token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50)
        )
      end.to raise_error(RuntimeError, "storage down")
    end

    it "derives the persisted batch flag from the merged pricing_mode so the two cannot drift" do
      stored = []
      allow(LlmCostTracker::Ledger::Store).to receive(:insert) do |event|
        stored << event
      end

      parsed_event = LlmCostTracker::Event.build(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 10, output_tokens: 5),
        pricing_mode: nil
      )
      expect(parsed_event.batch?).to be false

      described_class.record(event: parsed_event, pricing_mode: "batch_flex")

      expect(stored.last.pricing_mode).to eq("batch_flex")
      expect(stored.last.batch?).to be true
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
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 200, output_tokens: 80),
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
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1)
      )
      value = "second"
      second = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1)
      )

      expect(first.tags).to include(request_id: "first")
      expect(second.tags).to include(request_id: "second")
    end

    it "swallows a raising default_tags proc with a Logging.warn so a broken user callback doesn't crash every Tracker.record" do
      allow(LlmCostTracker::Logging).to receive(:warn)
      LlmCostTracker.configure do |c|
        c.default_tags = -> { raise "user proc blew up" }
      end

      event = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1)
      )

      expect(event).not_to be_nil
      expect(LlmCostTracker::Logging).to have_received(:warn).with(include("default_tags proc raised"))
    end

    it "merges scoped tags between default tags and explicit metadata" do
      LlmCostTracker.configure do |c|
        c.default_tags = { env: "test", feature: "default" }
      end

      event = LlmCostTracker.with_tags(feature: "chat", request_id: "req_123") do
        record(
          provider: "openai",
          model: "gpt-4o",
          token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1),
          metadata: { feature: "summary", user_id: 42 }
        )
      end

      expect(event.tags).to eq(env: "test", feature: "summary", request_id: "req_123", user_id: 42)
    end

    it "uses unknown when manual tracking has no model" do
      event = record(
        provider: "custom",
        model: nil,
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1)
      )

      expect(event.model).to eq("unknown")
      expect(event.cost).to be_nil
    end

    it "restores scoped tags after the block" do
      inside = LlmCostTracker.with_tags(request_id: "req_123") do
        record(
          provider: "openai",
          model: "gpt-4o",
          token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1)
        )
      end
      outside = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1)
      )

      expect(inside.tags).to include(request_id: "req_123")
      expect(outside.tags).not_to include(:request_id)
    end

    it "merges nested with_tags blocks; inner block wins on key conflict" do
      event = LlmCostTracker.with_tags(user_id: 5, feature: "outer") do
        LlmCostTracker.with_tags(feature: "chat", request_id: "req_xyz") do
          record(
            provider: "openai",
            model: "gpt-4o",
            token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1)
          )
        end
      end

      expect(event.tags).to include(user_id: 5, feature: "chat", request_id: "req_xyz")
    end

    it "keeps explicit token-like metadata as tags" do
      tags = {
        cache_read_input_tokens: 25,
        cache_write_input_tokens: 10,
        hidden_output_tokens: 5
      }

      event = record(
        provider: "anthropic",
        model: "claude-sonnet-4-6",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50, **tags),
        metadata: tags.merge(feature: "summarize")
      )

      expect(event.token_usage.total_tokens).to eq(185)
      expect(event.tags).to eq(tags.merge(feature: "summarize"))
    end

    it "uses pricing_mode without storing it as a tag" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "batchable-model" => {
            "input" => 1.0,
            "output" => 2.0,
            "batch_input" => 0.5,
            "batch_output" => 1.0
          }
        }
      end

      event = record(
        provider: "custom",
        model: "batchable-model",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000_000, output_tokens: 1_000_000),
        pricing_mode: "batch",
        metadata: { feature: "bulk" }
      )

      expect(event.pricing_mode).to eq("batch")
      expect(event.total_cost).to eq(1.5)
      expect(event.tags).to eq(feature: "bulk")
      expect(event.pricing_snapshot.dig("rates", "input", "amount")).to eq("0.5")
    end

    it "marks known token costs with unknown service charges as partial" do
      event = record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000, output_tokens: 0),
        service_line_items: [
          {
            component_key: "grounding_request",
            quantity: 1,
            cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN
          }
        ]
      )

      expect(event.total_cost).to eq(0.0025)
      expect(event.cost_status).to eq(LlmCostTracker::Billing::CostStatus::PARTIAL)
      service_line = event.line_items.find { |item| item.kind == "grounding_request" }
      expect(service_line).not_to be_nil
    end

    it "prices Anthropic web search service charges from provider tool rates" do
      event = record(
        provider: "anthropic",
        model: "claude-sonnet-4-6",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000, output_tokens: 0),
        service_line_items: [
          {
            component_key: "web_search_request",
            quantity: 2,
            cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN,
            pricing_basis: "provider_usage",
            provider_field: "usage.server_tool_use.web_search_requests"
          }
        ]
      )

      line_item = event.line_items.find { |item| item.kind == "web_search_request" }
      expect(event.cost_status).to eq(LlmCostTracker::Billing::CostStatus::COMPLETE)
      expect(event.total_cost).to eq(0.023)
      expect(line_item.cost_status).to eq(LlmCostTracker::Billing::CostStatus::COMPLETE)
      expect(line_item.cost).to eq(BigDecimal("0.02"))
      expect(line_item.rate_amount).to eq(BigDecimal("10.0"))
      expect(line_item.rate_quantity).to eq(BigDecimal("1000"))
      expect(line_item.price_key).to eq("service_charges.anthropic.web_search_request")
      expect(line_item.price_source).to eq("bundled")
      expect(line_item.provider_field).to eq("usage.server_tool_use.web_search_requests")
    end

    it "does not raise on unknown model for service-only events when behavior is :raise" do
      LlmCostTracker.configure { |c| c.unknown_pricing_behavior = :raise }

      expect do
        record(
          provider: "openai",
          model: "unrecognized-model",
          token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 0, output_tokens: 0),
          service_line_items: [
            { component_key: "web_search_request", quantity: 1, cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN }
          ]
        )
      end.not_to raise_error
    end

    it "keeps service-only unknown charges unknown without inventing total cost" do
      event = record(
        provider: "custom",
        model: "unknown-tool-model",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 0, output_tokens: 0),
        service_line_items: [
          {
            component_key: "web_search_request",
            quantity: 1,
            cost_status: LlmCostTracker::Billing::CostStatus::UNKNOWN
          }
        ]
      )

      expect(event.total_cost).to be_nil
      expect(event.cost_status).to eq(LlmCostTracker::Billing::CostStatus::UNKNOWN)
      expect(event.cost).to be_nil
    end

    it "uses captured provider pricing mode when the caller did not set one" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "priority-model" => {
            "input" => 1.0,
            "output" => 2.0,
            "priority_input" => 3.0,
            "priority_output" => 4.0
          }
        }
      end

      event = record(
        provider: "custom",
        model: "priority-model",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000_000, output_tokens: 1_000_000),
        capture_pricing_mode: "priority"
      )

      expect(event.pricing_mode).to eq("priority")
      expect(event.total_cost).to eq(7.0)
    end

    it "keeps explicit pricing_mode ahead of captured provider mode" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "multi-mode-model" => {
            "input" => 1.0,
            "output" => 2.0,
            "batch_input" => 0.5,
            "batch_output" => 1.0,
            "priority_input" => 3.0,
            "priority_output" => 4.0
          }
        }
      end

      event = record(
        provider: "custom",
        model: "multi-mode-model",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000_000, output_tokens: 1_000_000),
        capture_pricing_mode: "priority",
        pricing_mode: "batch"
      )

      expect(event.pricing_mode).to eq("batch")
      expect(event.total_cost).to eq(1.5)
    end

    it "keeps explicit pricing_mode metadata as a tag" do
      LlmCostTracker.configure do |c|
        c.pricing_overrides = {
          "metadata-mode-model" => {
            "input" => 1.0,
            "output" => 2.0,
            "batch_input" => 0.5,
            "batch_output" => 1.0
          }
        }
      end

      event = record(
        provider: "custom",
        model: "metadata-mode-model",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000_000, output_tokens: 1_000_000),
        metadata: { pricing_mode: "batch", feature: "bulk" }
      )

      expect(event.pricing_mode).to be_nil
      expect(event.total_cost).to eq(3.0)
      expect(event.tags).to eq(pricing_mode: "batch", feature: "bulk")
    end

    it "triggers budget callback when exceeded" do
      budget_data = nil

      LlmCostTracker.configure do |c|
        c.monthly_budget = 0.0001
        c.on_budget_exceeded = ->(data) { budget_data = data }
      end
      allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(month: 12.5)

      record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000_000, output_tokens: 1_000_000)
      )

      expect(budget_data).not_to be_nil
      expect(budget_data[:budget_type]).to eq(:monthly)
      expect(budget_data[:total]).to be > 0
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
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000_000, output_tokens: 0)
      )

      expect(budget_data).to include(
        budget_type: :per_call,
        total: event.total_cost,
        budget: 0.0001,
        last_event: event,
        stage: :post_spend
      )
    end

    it "does not trigger per-call budget callback when one event stays below the ceiling" do
      budget_data = nil

      LlmCostTracker.configure do |c|
        c.per_call_budget = 100.0
        c.on_budget_exceeded = ->(data) { budget_data = data }
      end

      record(
        provider: "openai",
        model: "gpt-4o",
        token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 0)
      )

      expect(budget_data).to be_nil
    end

    it "raises a budget error when configured to raise" do
      LlmCostTracker.configure do |c|
        c.monthly_budget = 0.0001
        c.budget_exceeded_behavior = :raise
      end
      allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(month: 12.5)

      expect do
        record(
          provider: "openai",
          model: "gpt-4o",
          token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000_000, output_tokens: 1_000_000)
        )
      end.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
        expect(error.budget_type).to eq(:monthly)
        expect(error.total).to be > error.budget
        expect(error.last_event.provider).to eq("openai")
      }
    end

    it "checks the daily budget before the monthly budget after recording" do
      LlmCostTracker.configure do |c|
        c.daily_budget = 0.0001
        c.monthly_budget = 0.0001
        c.budget_exceeded_behavior = :raise
      end
      allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(day: 12.5, month: 12.5)

      expect do
        record(
          provider: "openai",
          model: "gpt-4o",
          token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000_000, output_tokens: 1_000_000)
        )
      end.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
        expect(error.budget_type).to eq(:daily)
        expect(error.total).to eq(12.5)
      }
    end

    it "checks the monthly budget before the daily budget before recording" do
      LlmCostTracker.configure do |c|
        c.daily_budget = 0.0001
        c.monthly_budget = 0.0001
        c.budget_exceeded_behavior = :block_requests
      end
      allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(month: 12.5, day: 12.5)

      expect do
        LlmCostTracker::Budget.enforce!
      end.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
        expect(error.budget_type).to eq(:monthly)
        expect(error.total).to eq(12.5)
      }
    end

    it "does not fire on_budget_exceeded from preflight in :block_requests mode" do
      callback_calls = []
      LlmCostTracker.configure do |c|
        c.daily_budget = 0.0001
        c.budget_exceeded_behavior = :block_requests
        c.on_budget_exceeded = ->(payload) { callback_calls << payload }
      end
      allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(day: 12.5)

      expect { LlmCostTracker::Budget.enforce! }.to raise_error(LlmCostTracker::BudgetExceededError)
      expect(callback_calls).to be_empty
    end

    it "skips preflight totals when no period budget is configured" do
      LlmCostTracker.configure do |c|
        c.budget_exceeded_behavior = :block_requests
      end

      expect(LlmCostTracker::Ledger::Period::Totals).not_to receive(:call)

      LlmCostTracker::Budget.enforce!
    end

    it "blocks pre-send when prior spend plus the estimate exceeds the daily budget" do
      LlmCostTracker.configure do |c|
        c.daily_budget = 10.0
        c.budget_exceeded_behavior = :block_requests
      end
      allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(day: 8.0)

      expect do
        LlmCostTracker::Budget.enforce!(
          provider: "openai",
          model: "gpt-4o",
          request: { input: "x" * 4_000_000 }
        )
      end.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
        expect(error.budget_type).to eq(:daily)
        expect(error.stage).to eq(:pre_send)
        expect(error.last_event).to be_nil
        expect(error.total).to be > error.budget
      }
    end

    it "does not block pre-send when prior spend plus the estimate stays under the daily budget" do
      LlmCostTracker.configure do |c|
        c.daily_budget = 100.0
        c.budget_exceeded_behavior = :block_requests
      end
      allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(day: 1.0)

      expect do
        LlmCostTracker::Budget.enforce!(
          provider: "openai",
          model: "gpt-4o",
          request: { input: "x" * 4_000_000 }
        )
      end.not_to raise_error
    end

    it "blocks pre-send when the estimate alone exceeds the per_call budget" do
      LlmCostTracker.configure do |c|
        c.per_call_budget = 0.5
        c.budget_exceeded_behavior = :block_requests
      end

      expect do
        LlmCostTracker::Budget.enforce!(
          provider: "openai",
          model: "gpt-4o",
          request: { input: "x" * 4_000_000 }
        )
      end.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
        expect(error.budget_type).to eq(:per_call)
        expect(error.stage).to eq(:pre_send)
        expect(error.last_event).to be_nil
      }
    end

    it "does not pre-send block when the estimate fits under per_call_budget" do
      LlmCostTracker.configure do |c|
        c.per_call_budget = 10.0
        c.budget_exceeded_behavior = :block_requests
      end

      expect do
        LlmCostTracker::Budget.enforce!(
          provider: "openai",
          model: "gpt-4o",
          request: { input: "x" * 400 }
        )
      end.not_to raise_error
    end

    it "honors `enforce_budget: true` on `LlmCostTracker.track` even when the global policy is :notify, so per-call DSL can opt into pre-send fail-fast" do
      LlmCostTracker.configure do |c|
        c.per_call_budget = 0.0001
        c.budget_exceeded_behavior = :notify
      end

      expect do
        LlmCostTracker.track(
          provider: "openai", model: "gpt-4o",
          tokens: { input: 10_000, output: 10_000 },
          enforce_budget: true
        )
      end.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
        expect(error.budget_type).to eq(:per_call)
        expect(error.stage).to eq(:pre_send)
      }
    end

    it "includes priced service line items in the `enforce_budget` pre-send estimate" do
      LlmCostTracker.configure do |c|
        c.per_call_budget = 0.5
        c.budget_exceeded_behavior = :notify
      end

      expect do
        LlmCostTracker.track(
          provider: "openai", model: "gpt-4o", tokens: { input: 0, output: 0 },
          service_line_items: [
            { kind: "web_search_request", quantity: 1, unit: "request", cost: 1.0,
              currency: "USD", cost_status: "complete" }
          ],
          enforce_budget: true
        )
      end.to raise_error(LlmCostTracker::BudgetExceededError) { |error| expect(error.budget_type).to eq(:per_call) }
    end

    it "does not pre-send block on unknown models — falls through to the post-spend gate" do
      LlmCostTracker.configure do |c|
        c.daily_budget = 0.0001
        c.budget_exceeded_behavior = :block_requests
      end
      allow(LlmCostTracker::Ledger::Period::Totals).to receive(:call).and_return(day: 0.0)

      expect do
        LlmCostTracker::Budget.enforce!(
          provider: "openai",
          model: "no-such-model",
          request: { input: "x" * 4_000_000 }
        )
      end.not_to raise_error
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
          token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1_000_000, output_tokens: 0)
        )
      end.to raise_error(LlmCostTracker::BudgetExceededError) { |error|
        expect(error.budget_type).to eq(:per_call)
        expect(error.total).to be > error.budget
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

      log = capture_log do
        event = record(
          provider: "openai",
          model: "unknown-chat-model",
          token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50)
        )
      end

      expect(log).to match(/No pricing configured for model "unknown-chat-model"/)
      expect(event.cost).to be_nil
    end

    it "warns once per unknown model" do
      log = capture_log do
        2.times do
          record(
            provider: "openai",
            model: "unknown-model-dedup",
            token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50)
          )
        end
      end

      expect(log.scan('No pricing configured for model "unknown-model-dedup"').size).to eq(1)
    end

    it "caps the unknown-model warn cache so user-controlled model strings can't grow it unbounded" do
      stub_const("LlmCostTracker::Pricing::Unknown::WARN_CACHE_LIMIT", 2)

      log = capture_log do
        %w[unk-a unk-b unk-c].each do |model|
          record(
            provider: "openai",
            model: model,
            token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 1, output_tokens: 1)
          )
        end
      end

      expect(log.scan(/No pricing configured for model "unk-[abc]"/).size).to eq(2)
    end

    it "raises unknown pricing errors when configured" do
      LlmCostTracker.configure do |c|
        c.unknown_pricing_behavior = :raise
      end

      expect do
        record(
          provider: "openai",
          model: "unknown-chat-model",
          token_usage: LlmCostTracker::TokenUsage.build(input_tokens: 100, output_tokens: 50)
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
