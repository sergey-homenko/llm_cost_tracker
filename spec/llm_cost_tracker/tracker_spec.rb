# frozen_string_literal: true

require "spec_helper"

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
  end
end
